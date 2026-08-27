# acer-ec-web — localhost browser UI for the EC: keyboard backlight
# (brightness + colour) and fan control (profile, GPU-fan duty, auto).
#
# Why a plain Python-stdlib service and not Docker/npm:
#
#   Docker: the entire point is writing to host sysfs (/sys/class/leds,
#   /sys/kernel/acer_fanctl). /sys is mounted read-only in containers; the
#   only way around that is --privileged, which throws away every reason to
#   containerise. There is nothing to isolate here — the "app" is three
#   dozen lines of file I/O against the kernel.
#
#   npm: an express server means node + node_modules to do what http.server
#   already does. No deps is a feature: this module rebuilds on any NixOS
#   with just python3 in nixpkgs.
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

  server = pkgs.writeText "acer-ec-web.py" ''
    import json
    import glob
    import os
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    PORT = ${toString port}
    LED = "/sys/class/leds/acer_ec::kbd_backlight"
    FAN = "/sys/kernel/acer_fanctl"

    # The HTML UI. Kept inline: one file, no static root to manage.
    PAGE = """<!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>acer-ec</title>
    <style>
      :root { color-scheme: dark; }
      * { box-sizing: border-box; }
      body {
        margin: 0; min-height: 100vh; padding: 24px 16px 64px;
        background: #101014; color: #d5d7e0;
        font-family: system-ui, sans-serif;
      }
      h1 { font-size: 20px; font-weight: 600; margin: 0 0 20px; }
      h1 .dot {
        display: inline-block; width: 9px; height: 9px; border-radius: 50%;
        background: #444; margin-left: 10px; vertical-align: middle;
      }
      h1 .dot.ok { background: #4cc38a; }
      .grid { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); max-width: 900px; margin: 0 auto; }
      .card {
        background: #17171c; border: 1px solid #26262e; border-radius: 14px;
        padding: 18px;
      }
      .card h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .08em; color: #8b8fa3; margin: 0 0 14px; }
      .row { display: flex; align-items: center; gap: 12px; margin: 12px 0; flex-wrap: wrap; }
      .row label { min-width: 84px; font-size: 13px; color: #a9adbf; }
      input[type=range] { flex: 1; accent-color: #7aa2f7; min-width: 140px; }
      input[type=color] { width: 46px; height: 32px; border: 1px solid #33333d; border-radius: 8px; background: none; padding: 2px; cursor: pointer; }
      .val { font-variant-numeric: tabular-nums; font-size: 13px; color: #e6e8f0; min-width: 70px; text-align: right; }
      .stats { display: grid; grid-template-columns: 1fr 1fr; gap: 8px 16px; font-size: 13px; margin-top: 14px; }
      .stats .k { color: #8b8fa3; }
      .stats .v { color: #e6e8f0; font-variant-numeric: tabular-nums; text-align: right; }
      .seg { display: flex; gap: 6px; flex-wrap: wrap; }
      .seg button, button.act {
        background: #22222a; color: #d5d7e0; border: 1px solid #32323c;
        border-radius: 8px; padding: 7px 14px; font-size: 13px; cursor: pointer;
      }
      .seg button.on { background: #2b3f6b; border-color: #7aa2f7; color: #cfe0ff; }
      button.act { border-color: #3a3a46; }
      button.act:hover, .seg button:hover { border-color: #7aa2f7; }
      .err { color: #e06c75; font-size: 13px; min-height: 18px; margin-top: 10px; }
    </style>
    </head>
    <body>
    <div class="grid">
      <h1>acer-ec<span class="dot" id="dot"></span></h1>
    </div>
    <div class="grid">
      <div class="card">
        <h2>Keyboard backlight</h2>
        <div class="row">
          <label for="color">Colour</label>
          <input type="color" id="color" value="#0000ff">
          <span class="val" id="colorv"></span>
        </div>
        <div class="row">
          <label for="bright">Brightness</label>
          <input type="range" id="bright" min="0" max="255" value="0">
          <span class="val" id="brightv"></span>
        </div>
      </div>
      <div class="card">
        <h2>Fans</h2>
        <div class="row">
          <label>Profile</label>
          <div class="seg" id="profiles">
            <button data-p="1">1 &middot; quiet</button>
            <button data-p="2">2 &middot; balanced</button>
            <button data-p="3">3</button>
            <button data-p="4">4 &middot; performance</button>
          </div>
        </div>
        <div class="row">
          <label for="fan2">GPU fan</label>
          <input type="range" id="fan2" min="0" max="255" value="0">
          <span class="val" id="fan2v"></span>
          <button class="act" id="auto">auto</button>
        </div>
        <div class="stats">
          <span class="k">CPU fan</span><span class="v" id="s_fan1"></span>
          <span class="k">GPU fan</span><span class="v" id="s_fan2"></span>
          <span class="k">CPU duty</span><span class="v" id="s_duty1"></span>
          <span class="k">GPU duty</span><span class="v" id="s_duty2"></span>
          <span class="k">EC temp</span><span class="v" id="s_temp"></span>
        </div>
      </div>
    </div>
    <div class="grid"><div class="err" id="err"></div></div>
    <script>
      var errEl = document.getElementById("err");
      function fail(msg) { errEl.textContent = msg || ""; }

      function api(path, body) {
        return fetch(path, body ? {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body)
        } : undefined).then(function (r) {
          return r.json().then(function (j) {
            if (!r.ok) throw new Error(j.error || r.status);
            return j;
          });
        });
      }

      function toHex(c) {
        var p = c.split(" ").map(Number);
        return "#" + p.map(function (v) {
          var h = v.toString(16);
          return h.length < 2 ? "0" + h : h;
        }).join("");
      }

      var fan2Timer = null, brightTimer = null;
      function render(s) {
        document.getElementById("dot").className = s.available ? "dot ok" : "dot";
        var kbd = s.kbd, fan = s.fan;
        document.getElementById("colorv").textContent = kbd.color || "-";
        document.getElementById("brightv").textContent = kbd.brightness + " / " + kbd.max_brightness;
        if (kbd.color) {
          var hex = toHex(kbd.color);
          document.getElementById("color").value = hex;
        }
        var bEl = document.getElementById("bright");
        bEl.max = kbd.max_brightness;
        if (document.activeElement !== bEl) bEl.value = kbd.brightness;
        var f2 = document.getElementById("fan2");
        if (document.activeElement !== f2 && fan.fan2.duty != null) f2.value = fan.fan2.duty;
        document.getElementById("fan2v").textContent = (fan.fan2.duty != null ? fan.fan2.duty : "-");
        var btns = document.querySelectorAll("#profiles button");
        for (var i = 0; i < btns.length; i++) {
          btns[i].className = Number(btns[i].getAttribute("data-p")) === fan.profile ? "on" : "";
        }
        document.getElementById("s_fan1").textContent = (fan.fan1.rpm || "-") + " rpm";
        document.getElementById("s_fan2").textContent = (fan.fan2.rpm || "-") + " rpm";
        document.getElementById("s_duty1").textContent = fan.fan1.duty != null ? fan.fan1.duty : "-";
        document.getElementById("s_duty2").textContent = fan.fan2.duty != null ? fan.fan2.duty : "-";
        document.getElementById("s_temp").textContent = fan.temp != null ? fan.temp.toFixed(0) + " °C" : "-";
      }

      function poll() {
        api("/api/status").then(render).catch(function (e) { fail(e.message); });
      }

      document.getElementById("color").addEventListener("change", function () {
        api("/api/kbd", { color: this.value }).then(render).catch(function (e) { fail(e.message); });
      });
      document.getElementById("bright").addEventListener("input", function () {
        var el = this;
        document.getElementById("brightv").textContent = el.value;
        if (brightTimer) clearTimeout(brightTimer);
        brightTimer = setTimeout(function () {
          api("/api/kbd", { brightness: Number(el.value) }).catch(function (e) { fail(e.message); });
        }, 150);
      });
      document.getElementById("fan2").addEventListener("input", function () {
        var el = this;
        document.getElementById("fan2v").textContent = el.value;
        if (fan2Timer) clearTimeout(fan2Timer);
        fan2Timer = setTimeout(function () {
          api("/api/fan", { fan2_duty: Number(el.value) }).catch(function (e) { fail(e.message); });
        }, 250);
      });
      document.getElementById("auto").addEventListener("click", function () {
        api("/api/fan", { auto: true }).then(render).catch(function (e) { fail(e.message); });
      });
      var btns = document.querySelectorAll("#profiles button");
      for (var i = 0; i < btns.length; i++) {
        btns[i].addEventListener("click", function () {
          api("/api/fan", { profile: Number(this.getAttribute("data-p")) })
            .then(render).catch(function (e) { fail(e.message); });
        });
      }
      poll();
      setInterval(poll, 2000);
    </script>
    </body>
    </html>
    """

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

    class Handler(BaseHTTPRequestHandler):
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
            elif self.path == "/":
                body = PAGE.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_json(404, {"error": "not found"})

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
