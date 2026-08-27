# acer-ec-web — localhost browser UI for the EC: keyboard backlight
# (brightness + colour) and fan control (profile, GPU-fan duty, auto).
#
# Why this shape — a Nix-built static frontend behind a Python-stdlib
# server — and not Docker or a node runtime:
#
#   Docker: the entire point is writing to host sysfs (/sys/class/leds,
#   /sys/kernel/acer_fanctl). /sys is mounted read-only in containers; the
#   only way around that is --privileged, which throws away every reason to
#   containerise. There is nothing to isolate here — the "app" is three
#   dozen lines of file I/O against the kernel.
#
#   node at runtime: the UI is a real React + ThreeUI app now (./acer-ec-web/app,
#   Vite build), but it is built into plain static files by buildNpmPackage
#   at Nix build time. What runs on the system is still just python3 +
#   http.server pointing at that static root — no node, no node_modules,
#   no express. The JSON API is unchanged; only the markup under / moved
#   out of this file.
#
# Security posture, matching the sysfs permissions in acer-ec.nix:
#   - Binds 127.0.0.1 only. Never 0.0.0.0 — anything else on the LAN must
#     not be able to spin the fans or flash the keyboard.
#   - Runs as a DynamicUser in group "video": exactly the privileges the
#     udev rule / tmpfiles rules already grant the desktop, no more.
#   - fan1_duty_set is deliberately NOT exposed. It stays root-only per the
#     comment in acer-ec.nix: SCMD 0x68 carries both duties and nothing on
#     the EC side would catch a browser tab stalling the CPU fan.
{ config, pkgs, ... }:

let
  # Bind address. 127.0.0.1 on purpose — see the security note above.
  port = 8077;

  # The React + ThreeUI panel. src is the whole app tree (package.json,
  # package-lock.json, vite.config.ts, src/); the derivation runs
  # `npm run build` (tsc -b && vite build) and installs the dist/ output.
  # npmDepsHash pins the npm dependency fetch — when package-lock.json
  # changes, set it back to pkgs.lib.fakeHash, build, and paste the hash
  # from the error.
  frontend = pkgs.buildNpmPackage {
    pname = "acer-ec-web-frontend";
    version = "1.0.0";
    src = ./acer-ec-web/app;
    npmDepsHash = "sha256-XxAeVI9BaDG/0rrUPApOdNUv7EE3Sq2Fbw9OZ8kGU/w=";
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r dist/. $out/
      runHook postInstall
    '';
  };

  server = pkgs.writeText "acer-ec-web.py" ''
    import json
    import glob
    import os
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

    PORT = ${toString port}
    LED = "/sys/class/leds/acer_ec::kbd_backlight"
    FAN = "/sys/kernel/acer_fanctl"

    # The built frontend (index.html + assets), produced by buildNpmPackage
    # above. The server only reads from here.
    STATIC = "${frontend}"

    def read(path, default=None):
        try:
            with open(path) as f:
                return f.read().strip()
        except OSError:
            return default

    def write(path, text):
        with open(path, "w") as f:
            f.write(text)

    def hwmon_temp():
        # The driver also registers a hwmon device; temp1_input there is
        # millidegrees C per hwmon convention. Prefer it over the raw
        # tmp_temp kobject, whose unit is undocumented.
        for name in glob.glob("/sys/class/hwmon/hwmon*/name"):
            if read(name) == "acer_ec":
                t = read(os.path.dirname(name) + "/temp1_input")
                if t and t.isdigit():
                    return int(t) / 1000.0
        return None

    def status():
        avail = os.path.isdir(FAN) and os.path.isdir(LED)
        return {
            "available": avail,
            "kbd": {
                "brightness": int(read(LED + "/brightness") or 0),
                "max_brightness": int(read(LED + "/max_brightness") or 255),
                "color": read(LED + "/multi_intensity") or "",
            },
            "fan": {
                "profile": int(read(FAN + "/profile") or 0),
                "fan1": {"duty": read(FAN + "/fan1_duty"), "rpm": read(FAN + "/fan1_rpm")},
                "fan2": {"duty": read(FAN + "/fan2_duty"), "rpm": read(FAN + "/fan2_rpm")},
                "temp": hwmon_temp(),
            },
        }

    def parse_color(v):
        # Accepts "#rrggbb" (from <input type=color>), "r g b", or [r,g,b].
        if isinstance(v, str) and v.startswith("#") and len(v) == 7:
            return [int(v[i:i+2], 16) for i in (1, 3, 5)]
        if isinstance(v, str):
            v = v.replace(",", " ").split()
        if not isinstance(v, list) or len(v) != 3:
            raise ValueError("colour must be #rrggbb or three 0-255 values")
        out = []
        for c in v:
            c = int(c)
            if not 0 <= c <= 255:
                raise ValueError("colour values must be 0-255")
            out.append(c)
        return out

    # SimpleHTTPRequestHandler does the static side: "/" maps to
    # index.html in STATIC, asset paths keep their built names, content
    # types and path-traversal protection come for free, and unknown
    # non-API paths get its plain 404. The /api branch below is carved
    # out first so API errors stay JSON.
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=STATIC, **kwargs)

        def send_json(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/api/status":
                self.send_json(200, status())
            elif self.path.startswith("/api/") or self.path == "/api":
                self.send_json(404, {"error": "not found"})
            else:
                super().do_GET()

        def do_POST(self):
            try:
                n = int(self.headers.get("Content-Length") or 0)
                req = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                self.send_json(400, {"error": "invalid JSON"})
                return
            try:
                self.apply(self.path, req)
            except (ValueError, OSError) as e:
                self.send_json(400, {"error": str(e)})
                return
            self.send_json(200, dict({"ok": True}, **status()))

        def apply(self, path, req):
            if path == "/api/kbd":
                if "color" in req:
                    rgb = parse_color(req["color"])
                    write(LED + "/multi_intensity", " ".join(str(c) for c in rgb))
                if "brightness" in req:
                    b = int(req["brightness"])
                    mx = int(read(LED + "/max_brightness") or 255)
                    if not 0 <= b <= mx:
                        raise ValueError("brightness must be 0-" + str(mx))
                    write(LED + "/brightness", str(b))
            elif path == "/api/fan":
                if "profile" in req:
                    p = int(req["profile"])
                    if not 1 <= p <= 4:
                        raise ValueError("profile must be 1-4")
                    write(FAN + "/profile", str(p))
                if "fan2_duty" in req:
                    d = int(req["fan2_duty"])
                    if not 0 <= d <= 255:
                        raise ValueError("fan2_duty must be 0-255")
                    write(FAN + "/fan2_duty_set", str(d))
                if req.get("auto"):
                    # Any value accepted; the store handler ignores it.
                    write(FAN + "/fan_auto", "1")
            else:
                raise ValueError("not found")

        def log_message(self, fmt, *args):
            pass  # keep journald quiet; errors still surface as HTTP codes

    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
  '';
in
{
  systemd.services.acer-ec-web = {
    description = "acer-ec localhost web UI (keyboard backlight + fans)";
    wantedBy = [ "multi-user.target" ];
    # tmpfiles relaxes the fanctl kobjects; udev the LED files. Both have
    # run by the time multi-user.target is reached.
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${server}";
      DynamicUser = true;
      SupplementaryGroups = "video";
      Restart = "on-failure";
      RestartSec = 5;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      # NOTE: deliberately NO ProtectKernelTunables — it mounts /sys
      # read-only, which is the entire function of this service.
      RestrictAddressFamilies = [ "AF_INET" ];
    };
  };
}
