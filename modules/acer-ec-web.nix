# acer-ec-web — localhost browser UI for the EC: keyboard backlight
# (brightness, colour and software lighting effects) and fan control
# (profile, GPU-fan duty, auto).
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
#   no express. Only the markup under / moved out of this file.
#
# Lighting effects live HERE, in the server, not in the browser. The LED
# has no effect engine of its own: acer_ec::kbd_backlight exposes only
# brightness and multi_intensity (one RGB zone), so breathing/cycling is
# something that has to be written to sysfs on a timer. Putting that timer
# in the page would mean the effect dies with the tab and twenty HTTP
# round-trips a second; putting it in this service means the keyboard keeps
# breathing with the browser closed. The effect thread blocks on an Event
# while the mode is "static", so idle cost is exactly zero.
#
# Effect state is deliberately in-memory: a restart of this service leaves
# the keyboard on whatever colour it last wrote and the mode back at static.
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
    import colorsys
    import glob
    import json
    import math
    import os
    import threading
    import time
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

    PORT = ${toString port}
    LED = "/sys/class/leds/acer_ec::kbd_backlight"
    FAN = "/sys/kernel/acer_fanctl"

    # The built frontend (index.html + assets), produced by buildNpmPackage
    # above. The server only reads from here.
    STATIC = "${frontend}"

    # Effect tick. 20 Hz is smooth to the eye and gentle on the EC — every
    # push is also deduplicated against the last value written, so a slow
    # breath spends most ticks writing nothing at all.
    TICK = 0.05
    MODES = ("static", "breathing", "hue", "palette", "reactive")

    # How long a /api/status response may be reused before the EC is read
    # again. This is a power control, not a performance one.
    #
    # Every read under /sys/kernel/acer_fanctl is an ACPI SCMD exchange, and
    # each exchange is many single-byte EC transactions — each of which raises
    # GPE 0x6E, the embedded controller's own interrupt (see the boot log:
    # "ACPI: EC: GPE=0x6e"). One status response touches eight such files, so
    # the panel polling once a second was measured driving ~540 GPE/s and
    # holding the irq/9-acpi kernel thread at ~5% CPU permanently. That thread
    # never idles, which keeps the package out of its deep C-states.
    #
    # 2 s halves the sampling rate against the frontend's 1 s poll while
    # keeping fan RPM and temperature current enough to watch. Interactivity
    # does not suffer: every write path invalidates this immediately, so a
    # profile or colour change still reflects on the next response rather
    # than up to 2 s later.
    #
    # The frontend already skips its poll while the tab is hidden, so a
    # backgrounded panel costs nothing either way. This bounds the case that
    # actually burns power: the panel left open and visible on a second
    # workspace. Raise it if the rotors still feel too eager for the battery.
    STATUS_TTL = 2.0

    # Reactive mode maps EC temperature onto hue: COOL_C and below is the
    # green end of the sweep, HOT_C and above is red.
    COOL_C = 45.0
    HOT_C = 85.0

    def read(path, default=None):
        try:
            with open(path) as f:
                return f.read().strip()
        except OSError:
            return default

    def write(path, text):
        with open(path, "w") as f:
            f.write(text)

    def write_quiet(path, text):
        # The effect thread must survive a transient EC write failure; a
        # dropped frame is invisible, a dead thread is not.
        try:
            write(path, text)
            return True
        except OSError:
            return False

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

    def clamp(v, lo, hi):
        return lo if v < lo else (hi if v > hi else v)

    def hsv(h, s, v):
        r, g, b = colorsys.hsv_to_rgb(h % 1.0, s, v)
        return [int(round(r * 255)), int(round(g * 255)), int(round(b * 255))]

    def mix(a, b, t):
        return [int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3)]

    def rgb_str(c):
        return " ".join(str(int(x)) for x in c)

    def rgb_hex(c):
        return "#" + "".join("%02x" % int(x) for x in c)

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

    # ------------------------------------------------------------------
    # Effect state
    #
    # "color" and "brightness" are the *base* values the user picked, not
    # whatever the effect thread last wrote to sysfs — brightness is the
    # peak a breath swings up to, colour is what static/breathing show and
    # what the cycling modes fall back to. Holding them here is what lets
    # the sliders sit still while the keyboard is mid-pulse.
    # ------------------------------------------------------------------
    lock = threading.Lock()
    wake = threading.Event()
    effect = {
        "mode": "static",
        "speed": 1.0,
        "smooth": True,
        "color": [0, 0, 255],
        "palette": [[255, 40, 40], [40, 120, 255], [180, 40, 255]],
        "brightness": 255,
    }

    MAX_BRIGHTNESS = int(read(LED + "/max_brightness") or 255)

    def load_base():
        with lock:
            b = read(LED + "/brightness")
            if b and b.isdigit():
                effect["brightness"] = int(b)
            c = read(LED + "/multi_intensity")
            if c:
                try:
                    effect["color"] = parse_color(c)
                except ValueError:
                    pass

    def push_color(c, cache):
        s = rgb_str(c)
        if cache.get("color") != s and write_quiet(LED + "/multi_intensity", s):
            cache["color"] = s

    def push_brightness(b, cache):
        b = int(clamp(int(b), 0, MAX_BRIGHTNESS))
        if cache.get("brightness") != b and write_quiet(LED + "/brightness", str(b)):
            cache["brightness"] = b

    def engine():
        cache = {}
        phase = 0.0
        last = time.monotonic()
        temp = None
        temp_at = 0.0
        reactive = None
        while True:
            with lock:
                mode = effect["mode"]
                speed = effect["speed"]
                smooth = effect["smooth"]
                base = list(effect["color"])
                peak = effect["brightness"]
                palette = [list(c) for c in effect["palette"]]

            if mode == "static" or not os.path.isdir(LED):
                # Nothing to animate: sleep on the event until a mode
                # change wakes us. The 5 s timeout only exists so a LED
                # that appears late is picked up without a request.
                cache.clear()
                reactive = None
                wake.wait(5.0)
                wake.clear()
                last = time.monotonic()
                continue

            now = time.monotonic()
            # Accumulating phase rather than deriving it from a start time
            # means a speed change bends the curve instead of jumping it.
            phase += clamp(now - last, 0.0, 0.5) * speed
            last = now

            if mode == "breathing":
                # speed 1.0 == one full breath every four seconds.
                level = 0.5 - 0.5 * math.cos(phase * 2.0 * math.pi * 0.25)
                push_color(base, cache)
                push_brightness(peak * (0.05 + 0.95 * level), cache)
            elif mode == "hue":
                # speed 1.0 == one lap of the wheel every 12.5 seconds.
                push_brightness(peak, cache)
                push_color(hsv(phase * 0.08, 1.0, 1.0), cache)
            elif mode == "palette":
                pal = palette or [base]
                step = phase * 0.5  # speed 1.0 == one swatch every 2 s
                i = int(step) % len(pal)
                frac = step - int(step)
                if smooth and len(pal) > 1:
                    # Hold the swatch, then cross-fade over the last third
                    # with a smoothstep so the handover has no hard edge.
                    t = clamp((frac - 0.65) / 0.35, 0.0, 1.0)
                    c = mix(pal[i], pal[(i + 1) % len(pal)], t * t * (3.0 - 2.0 * t))
                else:
                    c = pal[i]
                push_brightness(peak, cache)
                push_color(c, cache)
            elif mode == "reactive":
                if now - temp_at > 1.0:
                    temp = hwmon_temp()
                    temp_at = now
                if temp is not None:
                    x = clamp((temp - COOL_C) / (HOT_C - COOL_C), 0.0, 1.0)
                    target = hsv(0.45 * (1.0 - x), 1.0, 1.0)
                    # Ease towards the target so a one-degree jitter in the
                    # EC reading does not show up as a flicker on the keys.
                    reactive = target if reactive is None else mix(reactive, target, 0.05)
                    push_brightness(peak, cache)
                    push_color(reactive, cache)

            time.sleep(TICK)

    def apply_base(mode):
        # Called after any state change: put sysfs back into a state the
        # chosen mode owns. static and breathing show the base colour; every
        # mode except breathing owns brightness outright.
        if mode in ("static", "breathing"):
            with lock:
                write_quiet(LED + "/multi_intensity", rgb_str(effect["color"]))
        if mode != "breathing":
            with lock:
                write_quiet(LED + "/brightness", str(int(effect["brightness"])))

    # Guards status_cache only. Deliberately not `lock`: that one is held
    # while the effect state is mutated, and status_uncached() takes it.
    status_lock = threading.Lock()
    status_cache = {"at": 0.0, "val": None}

    def invalidate_status():
        # Called after anything that writes to the EC, so the next poll
        # re-reads instead of serving a value from before the write.
        with status_lock:
            status_cache["at"] = 0.0

    def status():
        now = time.monotonic()
        with status_lock:
            if status_cache["val"] is not None and now - status_cache["at"] < STATUS_TTL:
                return status_cache["val"]
        # Read outside status_lock: the EC exchange is slow and there is no
        # harm in two racing pollers both refreshing, only in serialising
        # every caller behind the lock while the EC is talked to.
        val = status_uncached()
        with status_lock:
            status_cache["val"] = val
            status_cache["at"] = time.monotonic()
        return val

    def status_uncached():
        avail = os.path.isdir(FAN) and os.path.isdir(LED)
        with lock:
            mode = effect["mode"]
            if mode == "static":
                # Static means sysfs is the source of truth — something
                # else may have changed it. Track it so a later mode switch
                # starts from what the keyboard is actually showing.
                b = read(LED + "/brightness")
                if b and b.isdigit():
                    effect["brightness"] = int(b)
                c = read(LED + "/multi_intensity")
                if c:
                    try:
                        effect["color"] = parse_color(c)
                    except ValueError:
                        pass
            kbd = {
                "brightness": int(effect["brightness"]),
                "max_brightness": MAX_BRIGHTNESS,
                "color": rgb_str(effect["color"]),
                "effect": {
                    "mode": mode,
                    "speed": effect["speed"],
                    "smooth": effect["smooth"],
                    "palette": [rgb_hex(c) for c in effect["palette"]],
                },
            }
        return {
            "available": avail,
            "kbd": kbd,
            "fan": {
                "profile": int(read(FAN + "/profile") or 0),
                "fan1": {"duty": read(FAN + "/fan1_duty"), "rpm": read(FAN + "/fan1_rpm")},
                "fan2": {"duty": read(FAN + "/fan2_duty"), "rpm": read(FAN + "/fan2_rpm")},
                "temp": hwmon_temp(),
            },
        }

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
                # A write may have partially landed before raising, so drop
                # the cache on the error path too.
                invalidate_status()
                self.send_json(400, {"error": str(e)})
                return
            invalidate_status()
            self.send_json(200, dict({"ok": True}, **status()))

        def apply(self, path, req):
            if path == "/api/kbd/effect":
                self.set_effect(req)
            elif path == "/api/kbd":
                self.set_kbd(req)
            elif path == "/api/fan":
                self.set_fan(req)
            else:
                raise ValueError("not found")

        def set_kbd(self, req):
            with lock:
                mode = effect["mode"]
                if "color" in req:
                    effect["color"] = parse_color(req["color"])
                if "brightness" in req:
                    b = int(req["brightness"])
                    if not 0 <= b <= MAX_BRIGHTNESS:
                        raise ValueError("brightness must be 0-" + str(MAX_BRIGHTNESS))
                    effect["brightness"] = b
            # Under a cycling mode these are only the base the effect falls
            # back to, so the write is left to the engine; under static and
            # breathing the change has to land now to feel direct.
            if mode in ("static", "breathing"):
                if "color" in req:
                    write(LED + "/multi_intensity", rgb_str(effect["color"]))
                if "brightness" in req and mode == "static":
                    write(LED + "/brightness", str(int(effect["brightness"])))
            elif "brightness" in req:
                write(LED + "/brightness", str(int(effect["brightness"])))

        def set_effect(self, req):
            with lock:
                if "mode" in req:
                    m = req["mode"]
                    if m not in MODES:
                        raise ValueError("mode must be one of " + ", ".join(MODES))
                    effect["mode"] = m
                if "speed" in req:
                    s = float(req["speed"])
                    if not 0.1 <= s <= 5.0:
                        raise ValueError("speed must be 0.1-5.0")
                    effect["speed"] = s
                if "smooth" in req:
                    effect["smooth"] = bool(req["smooth"])
                if "color" in req:
                    effect["color"] = parse_color(req["color"])
                if "palette" in req:
                    pal = req["palette"]
                    if not isinstance(pal, list) or not 1 <= len(pal) <= 8:
                        raise ValueError("palette must be 1-8 colours")
                    effect["palette"] = [parse_color(c) for c in pal]
                mode = effect["mode"]
            apply_base(mode)
            wake.set()

        def set_fan(self, req):
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

        def log_message(self, fmt, *args):
            pass  # keep journald quiet; errors still surface as HTTP codes

    load_base()
    threading.Thread(target=engine, daemon=True).start()
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
