# acer-ec-web — localhost browser UI for the EC: keyboard backlight
# (brightness, colour and software lighting effects), fan control (profile,
# GPU-fan duty, auto), and the system telemetry that makes those controls
# make sense — CPU and memory load, both GPUs, and where the watts go.
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
#   - The telemetry half is read-only everywhere: /proc, powercap, the
#     battery gauge, and nvidia-smi as a query. The one privilege it adds is
#     group-video read on the RAPL energy counters (see the udev rule at the
#     bottom of this file), which is the difference between showing watts
#     and showing an em dash.
{ config, lib, pkgs, ... }:

let
  # Bind address. 127.0.0.1 on purpose — see the security note above.
  port = 8077;

  # nvidia-smi, as a store path, or the Python literal None on a machine
  # with no NVIDIA driver. The service runs as a DynamicUser with no PATH
  # worth trusting, and querying a GPU that is not there should be dead
  # code rather than a subprocess that fails every five seconds.
  nvidiaSmi =
    if builtins.elem "nvidia" config.services.xserver.videoDrivers
    then ''"${config.hardware.nvidia.package.bin}/bin/nvidia-smi"''
    else "None";

  # upower's battery levels (power.nix) as a Python dict literal. null
  # when upower is off, so the panel just omits the power-off estimate.
  upowerLevels =
    let
      up = config.services.upower;
      lvl = v: if up.enable then toString v else "None";
    in
    ''{"low": ${lvl up.percentageLow}, "critical": ${lvl up.percentageCritical}, "action": ${lvl up.percentageAction}}'';

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
    npmDepsHash = "sha256-r4wxcqHcHKqE+u3IaoMtdmtPRItGBBLhUnOkbUsVDRw=";
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
    import subprocess
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

    # ------------------------------------------------------------------
    # System metrics
    #
    # Everything below is read-only and has nothing to do with the EC:
    # /proc for CPU and memory, powercap for the CPU energy counters, the
    # battery gauge for whole-system draw, and nvidia-smi for the discrete
    # GPU. It answers the question the fan controls raise but cannot answer
    # on their own — what is the machine actually spending, and on what.
    #
    # It is sampled by one background thread, not by the request, because
    # every number here is a *rate*: a difference between two readings over
    # the time between them. Computing that in the handler would mean the
    # first poll after a pause reported a several-minute average, and two
    # tabs polling out of phase would each consume the other's deltas.
    #
    # The thread stops sampling IDLE_AFTER seconds after the last
    # /api/metrics request and blocks on an Event, exactly as the effect
    # engine does. A panel nobody is looking at costs nothing; this file
    # exists to save power, not to spend it watching itself.
    # ------------------------------------------------------------------

    HZ = os.sysconf("SC_CLK_TCK")
    PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
    NCPU = os.cpu_count() or 1

    SAMPLE = 1.0        # seconds between base samples
    PROC_EVERY = 2      # base ticks between /proc/<pid> sweeps
    GPU_EVERY = 5       # base ticks between nvidia-smi runs
    IDLE_AFTER = 15.0   # stop sampling this long after the last request
    TOP_N = 8           # programs reported

    # Absolute path: this runs as a DynamicUser with no PATH worth trusting.
    # None on a machine with no NVIDIA driver, which turns the whole dGPU
    # branch off rather than shelling out to something that isn't there.
    NVIDIA_SMI = ${nvidiaSmi}
    NVIDIA_PCI = "/sys/bus/pci/drivers/nvidia"

    def read_int(path):
        try:
            return int(read(path))
        except (TypeError, ValueError):
            return None

    def hwmon_of(name):
        for p in glob.glob("/sys/class/hwmon/hwmon*/name"):
            if read(p) == name:
                return os.path.dirname(p)
        return None

    CORETEMP = hwmon_of("coretemp")

    def cpu_stat():
        # (busy, total) jiffies for the machine, then for each core. iowait
        # counts as idle: nothing executes during it, and calling a core
        # blocked on the disk "busy" makes the meter lie about the CPU.
        out = []
        try:
            with open("/proc/stat") as f:
                for line in f:
                    if not line.startswith("cpu"):
                        break
                    v = [int(x) for x in line.split()[1:]]
                    idle = v[3] + (v[4] if len(v) > 4 else 0)
                    out.append((sum(v) - idle, sum(v)))
        except (OSError, ValueError, IndexError):
            return []
        return out

    def cpu_freq():
        vals = [read_int(p) for p in
                glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq")]
        vals = [v for v in vals if v]
        return round(sum(vals) / len(vals) / 1000.0) if vals else None

    def cpu_temp():
        if not CORETEMP:
            return None
        v = read_int(CORETEMP + "/temp1_input")
        return v / 1000.0 if v is not None else None

    def meminfo():
        info = {}
        try:
            with open("/proc/meminfo") as f:
                for line in f:
                    k, _, rest = line.partition(":")
                    info[k] = int(rest.split()[0]) * 1024
        except (OSError, ValueError, IndexError):
            return None
        total = info.get("MemTotal", 0)
        # MemAvailable, not MemFree: the kernel's own estimate of what a new
        # allocation could actually get, which is the only one of the two
        # that means anything on a machine with a page cache.
        avail = info.get("MemAvailable", 0)
        swap_total = info.get("SwapTotal", 0)
        return {
            "total": total,
            "available": avail,
            "used": total - avail,
            "cached": info.get("Cached", 0) + info.get("Buffers", 0),
            "swap_total": swap_total,
            "swap_used": swap_total - info.get("SwapFree", 0),
        }

    def rapl_zones():
        # powercap zones, discovered once. The udev rule in this module
        # hands group video read access to energy_uj; without it every read
        # here returns None and the watt figures degrade to an em dash
        # rather than to a zero that reads like a measurement.
        zones = {}
        for d in sorted(glob.glob("/sys/class/powercap/intel-rapl:*")):
            name = read(d + "/name")
            if not name or name in zones:
                continue
            zones[name] = {
                "path": d + "/energy_uj",
                "wrap": read_int(d + "/max_energy_range_uj") or 0,
            }
        return zones

    RAPL = rapl_zones()

    def rapl_energy():
        out = {}
        for key, z in RAPL.items():
            v = read_int(z["path"])
            if v is not None:
                out[key] = v
        return out

    def rapl_watts(prev, cur, dt):
        if dt <= 0:
            return {}
        out = {}
        for key, v in cur.items():
            p = prev.get(key)
            if p is None:
                continue
            d = v - p
            if d < 0:
                # A fixed-width microjoule accumulator that wraps at
                # max_energy_range_uj, not at a power of two.
                d += RAPL[key]["wrap"]
            if d >= 0:
                out[key] = d / 1e6 / dt
        return out

    BATTERY = next(iter(sorted(glob.glob("/sys/class/power_supply/BAT*"))), None)
    ADAPTER = next(iter(sorted(glob.glob("/sys/class/power_supply/A[CD]*"))), None)

    # upower's thresholds from power.nix, so the panel can say how long until
    # the machine powers itself off rather than how long until a 0% it will
    # never actually reach.
    UPOWER = ${upowerLevels}

    # Time constant of the rate behind the time estimates. The gauge's
    # current_now is instantaneous — it swings 3x between an idle desktop
    # and a page load — and dividing the remaining charge by that gives an
    # estimate that jumps by hours every poll. 60 s averages over the bursts
    # while still following a real change (a game starting) within a minute
    # or two.
    BAT_TAU = 60.0
    # Below this much averaging the estimate is flagged as settling, and the
    # UI says so instead of presenting one second of current as a forecast.
    BAT_SETTLE = 20.0

    def battery(smooth):
        # `smooth` is the sampler's running state for the averaged rate; it
        # is dropped whenever the sampler idles, like every other baseline.
        if not BATTERY:
            return None
        state = read(BATTERY + "/status")
        volts = read_int(BATTERY + "/voltage_now")

        # The gauge speaks one of two dialects. energy_* / power_now are µWh
        # and µW; charge_* / current_now are µAh and µA. This pack speaks
        # charge. The estimate is done in whichever dialect the pack uses,
        # so remaining / rate is a ratio of like units and no voltage
        # conversion can skew it. Wh figures for display convert charge at
        # the design voltage, which is what upower does too: voltage_now
        # sags with load and would make "energy" wobble with the CPU.
        if read_int(BATTERY + "/energy_now") is not None:
            now = read_int(BATTERY + "/energy_now")
            full = read_int(BATTERY + "/energy_full")
            design = read_int(BATTERY + "/energy_full_design")
            rate = read_int(BATTERY + "/power_now")
            to_wh = lambda v: v / 1e6
            watts = abs(rate) / 1e6 if rate is not None else None
        else:
            now = read_int(BATTERY + "/charge_now")
            full = read_int(BATTERY + "/charge_full")
            design = read_int(BATTERY + "/charge_full_design")
            rate = read_int(BATTERY + "/current_now")
            vd = read_int(BATTERY + "/voltage_min_design") or volts
            to_wh = (lambda v: v * vd / 1e12) if vd else (lambda v: None)
            watts = (abs(rate) * volts / 1e12
                     if rate is not None and volts is not None else None)
        # Some gauges sign the rate by direction; status already says that.
        rate = abs(rate) if rate else None

        moving = state in ("Discharging", "Charging") and bool(rate)
        t = time.monotonic()
        if not moving or smooth.get("status") != state:
            # Plugging or unplugging changes the rate by an order of
            # magnitude; averaging across that would blend two regimes.
            smooth.clear()
        smooth["status"] = state
        if moving:
            avg = smooth.get("rate")
            if avg is None:
                smooth["rate"], smooth["since"] = float(rate), t
            else:
                dt = t - smooth["at"]
                smooth["rate"] = avg + (rate - avg) * (dt / (BAT_TAU + dt))
            smooth["at"] = t
        avg = smooth.get("rate")

        to_empty = to_full = to_action = None
        if avg and now is not None:
            if state == "Discharging":
                to_empty = now / avg * 3600
                if full and UPOWER["action"] is not None:
                    floor = full * UPOWER["action"] / 100.0
                    to_action = max(now - floor, 0) / avg * 3600
            elif state == "Charging" and full:
                # Linear, so it runs optimistic through the last ~10%, where
                # the charger tapers to constant voltage. Labelled "about".
                to_full = max(full - now, 0) / avg * 3600

        cycles = read_int(BATTERY + "/cycle_count")
        rnd = lambda v, n=1: round(v, n) if v is not None else None
        return {
            "status": state,
            "capacity": read_int(BATTERY + "/capacity"),
            "level": read(BATTERY + "/capacity_level"),
            # Only meaningful while discharging. On AC this gauge reports
            # the charge current, or nothing once the pack is full — either
            # way it is not what the machine is consuming.
            "watts": watts if state == "Discharging" else None,
            # Instantaneous flow in either direction, for the rate readout.
            "rate_w": rnd(watts, 2) if moving else None,
            "ac": (read_int(ADAPTER + "/online") == 1) if ADAPTER else None,
            "energy_wh": rnd(to_wh(now)) if now is not None else None,
            "full_wh": rnd(to_wh(full)) if full is not None else None,
            "design_wh": rnd(to_wh(design)) if design is not None else None,
            "health": round(full / design, 3) if full and design else None,
            # 0 is how most ACPI gauges say "not reported", not a new pack.
            "cycles": cycles or None,
            "voltage": rnd(volts / 1e6, 2) if volts is not None else None,
            "technology": read(BATTERY + "/technology"),
            "to_empty": round(to_empty) if to_empty is not None else None,
            "to_action": round(to_action) if to_action is not None else None,
            "to_full": round(to_full) if to_full is not None else None,
            "settling": bool(avg) and t - smooth.get("since", t) < BAT_SETTLE,
            "thresholds": UPOWER,
        }

    def find_igpu():
        for card in sorted(glob.glob("/sys/class/drm/card[0-9]")):
            drv = os.path.basename(os.path.realpath(card + "/device/driver"))
            if drv in ("i915", "xe"):
                return card
        return None

    IGPU = find_igpu()

    def igpu():
        # i915 exposes no busy percentage. A real one comes from the perf
        # interface, which needs CAP_PERFMON or a relaxed
        # perf_event_paranoid — privileges this service does not have and
        # should not be given for a readout. The render clock is the honest
        # answer to the same question: it sits at the floor when idle and
        # walks up under load, so it is reported as a clock and labelled as
        # one rather than dressed up as a percentage.
        if not IGPU:
            return None
        act = read_int(IGPU + "/gt_act_freq_mhz")
        if act is None:
            return None
        return {
            "freq_mhz": act,
            "min_mhz": read_int(IGPU + "/gt_RPn_freq_mhz"),
            "max_mhz": read_int(IGPU + "/gt_RP0_freq_mhz")
                       or read_int(IGPU + "/gt_max_freq_mhz"),
            "watts": None,  # filled from the RAPL uncore domain below
        }

    def dgpu_state():
        # Runtime power state straight from the PCI device, and the gate on
        # everything else here. This is a PRIME-offload laptop: the discrete
        # GPU spends its life in D3cold, and *asking* nvidia-smi anything
        # resumes it. A panel that polled unconditionally would hold a card
        # awake for the sake of telling you how much it draws while awake.
        for d in sorted(glob.glob(NVIDIA_PCI + "/0000:*")):
            return read(d + "/power/runtime_status") or "unknown"
        return None

    def smi(args, timeout=6.0):
        try:
            r = subprocess.run(
                [NVIDIA_SMI] + args,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=timeout,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if r.returncode != 0:
            return None
        return r.stdout.decode("utf-8", "replace")

    GPU_FIELDS = ("name,utilization.gpu,memory.used,memory.total,"
                  "power.draw,temperature.gpu,clocks.sm")

    def dgpu_sample():
        out = {"present": bool(NVIDIA_SMI) and os.path.isdir(NVIDIA_PCI)}
        if not out["present"]:
            return out
        state = dgpu_state()
        out["state"] = state
        if state != "active":
            return out  # asleep, and deliberately left that way
        txt = smi(["--query-gpu=" + GPU_FIELDS, "--format=csv,noheader,nounits"])
        if not txt or not txt.strip():
            return out
        row = [c.strip() for c in txt.strip().splitlines()[0].split(",")]
        if len(row) < 7:
            return out

        def n(v):
            try:
                return float(v)
            except ValueError:
                return None

        out["name"] = row[0]
        out["usage"] = (n(row[1]) or 0.0) / 100.0
        out["mem_used"] = (n(row[2]) or 0.0) * 1048576
        out["mem_total"] = (n(row[3]) or 0.0) * 1048576
        out["watts"] = n(row[4])
        out["temp"] = n(row[5])
        out["freq_mhz"] = n(row[6])
        return out

    def dgpu_procs(snap):
        # pmon takes a one-second sample of its own, so it only runs when
        # the GPU is both awake and doing something. Idle, every row would
        # be a dash and the second of subprocess would buy nothing.
        if snap.get("state") != "active":
            return {}
        if (snap.get("usage") or 0.0) <= 0.0 and (snap.get("mem_used") or 0) < 64 * 1048576:
            return {}
        txt = smi(["pmon", "-c", "1", "-s", "u"], timeout=8.0)
        if not txt:
            return {}
        out = {}
        for line in txt.splitlines():
            if line.startswith("#"):
                continue
            f = line.split()
            # gpu pid type sm mem enc dec ...; idle rows carry dashes.
            if len(f) < 4 or not f[1].isdigit():
                continue
            try:
                out[int(f[1])] = float(f[3])
            except ValueError:
                continue
        return out

    def proc_scan():
        out = {}
        for name in os.listdir("/proc"):
            if not name.isdigit():
                continue
            try:
                with open("/proc/" + name + "/stat") as f:
                    s = f.read()
            except OSError:
                continue  # exited between listdir and open, or not readable
            a = s.find("(")
            b = s.rfind(")")
            if a < 0 or b < a:
                continue
            # comm is the only field that may contain spaces or parens, so
            # everything after the last ")" splits cleanly. Field 3 (state)
            # is index 0 there: utime is 14, stime 15, rss in pages is 24.
            fields = s[b + 2:].split()
            if len(fields) < 22:
                continue
            try:
                out[int(name)] = (s[a + 1:b],
                                  int(fields[11]) + int(fields[12]),
                                  int(fields[21]) * PAGE_SIZE)
            except ValueError:
                continue
        return out

    def top_apps(prev, cur, busy_delta, dt, cpu_watts, gpu_pids, gpu_watts):
        # Grouped by command name: "chromium" is one thing the user can act
        # on, forty renderer processes are not. Summed RSS over-counts the
        # pages forks of one program share — it ranks, it does not account.
        apps = {}
        for pid, (comm, ticks, rss) in cur.items():
            p = prev.get(pid)
            # A pid reused by a different program since the last sweep would
            # otherwise show up as a huge negative or positive delta.
            d = ticks - p[1] if p and p[0] == comm else 0
            a = apps.get(comm)
            if a is None:
                a = apps[comm] = {"procs": 0, "ticks": 0, "rss": 0, "sm": 0.0}
            a["procs"] += 1
            a["ticks"] += max(d, 0)
            a["rss"] += rss
            a["sm"] += gpu_pids.get(pid, 0.0)
        sm_total = sum(a["sm"] for a in apps.values())
        rows = []
        for comm, a in apps.items():
            # Share of the CPU time actually executed in the window, which
            # is also the share of the measured package power attributed to
            # the program. It is an estimate and the UI says so: RAPL meters
            # the package, the battery meters the board, and nothing in this
            # machine meters a process.
            share = a["ticks"] / busy_delta if busy_delta > 0 else 0.0
            watts = cpu_watts * share if cpu_watts is not None else None
            gpu_pct = None
            if a["sm"] > 0.0:
                gpu_pct = a["sm"]
                if gpu_watts is not None and sm_total > 0.0:
                    watts = (watts or 0.0) + gpu_watts * (a["sm"] / sm_total)
            cpu_pct = 100.0 * a["ticks"] / (dt * HZ * NCPU) if dt > 0 else 0.0
            if cpu_pct < 0.05 and not gpu_pct:
                continue
            rows.append({
                "name": comm,
                "procs": a["procs"],
                "cpu": round(cpu_pct, 2),
                "rss": a["rss"],
                "watts": round(watts, 3) if watts is not None else None,
                "gpu": round(gpu_pct, 1) if gpu_pct is not None else None,
            })
        # Watts first, CPU as the tiebreak — and as the whole ordering when
        # the RAPL counters are unreadable and every row's watts are None.
        rows.sort(key=lambda r: (r["watts"] or 0.0, r["cpu"]), reverse=True)
        return rows[:TOP_N]

    metrics_lock = threading.Lock()
    metrics_wake = threading.Event()
    metrics_state = {"snapshot": {"ready": False}, "asked": 0.0}

    def metrics_touch():
        # Every /api/metrics request is also the "someone is watching"
        # signal. The frontend stops polling on a hidden tab, so a
        # backgrounded panel puts the sampler back to sleep by itself.
        with metrics_lock:
            metrics_state["asked"] = time.monotonic()
        metrics_wake.set()

    def metrics():
        with metrics_lock:
            return metrics_state["snapshot"]

    def sampler():
        prev_cpu = []
        prev_rapl = {}
        prev_procs = {}
        prev_at = 0.0
        prev_proc_at = 0.0
        prev_proc_busy = 0
        gpu = {"present": bool(NVIDIA_SMI)}
        gpu_pids = {}
        apps = []
        bat_smooth = {}
        tick = 0
        while True:
            with metrics_lock:
                idle = time.monotonic() - metrics_state["asked"] > IDLE_AFTER
            if idle:
                # Drop the baselines rather than keep them: by the time
                # anyone asks again they would be minutes old, and a rate
                # averaged over the pause is worse than no rate at all.
                prev_cpu, prev_rapl, prev_procs = [], {}, {}
                prev_at = prev_proc_at = 0.0
                gpu_pids, apps, tick = {}, [], 0
                bat_smooth = {}
                with metrics_lock:
                    metrics_state["snapshot"] = {"ready": False}
                metrics_wake.wait()
                metrics_wake.clear()
                continue

            now = time.monotonic()
            cpu = cpu_stat()
            energy = rapl_energy()
            dt = now - prev_at if prev_at else 0.0

            usage = None
            cores = []
            if prev_cpu and len(prev_cpu) == len(cpu):
                busy_d = cpu[0][0] - prev_cpu[0][0]
                total_d = cpu[0][1] - prev_cpu[0][1]
                if total_d > 0:
                    usage = round(clamp(busy_d / total_d, 0.0, 1.0), 3)
                for i in range(1, len(cpu)):
                    b = cpu[i][0] - prev_cpu[i][0]
                    t = cpu[i][1] - prev_cpu[i][1]
                    cores.append(round(clamp(b / t, 0.0, 1.0), 3) if t > 0 else 0.0)

            watts = rapl_watts(prev_rapl, energy, dt)
            pkg_w = watts.get("package-0")
            core_w = watts.get("core")
            unc_w = watts.get("uncore")
            psys_w = watts.get("psys")

            if tick % GPU_EVERY == 0:
                gpu = dgpu_sample()
            gpu_w = gpu.get("watts")

            if tick % PROC_EVERY == 0:
                procs = proc_scan()
                busy_now = cpu[0][0] if cpu else 0
                if prev_procs and prev_proc_at:
                    if tick % GPU_EVERY == 0:
                        gpu_pids = dgpu_procs(gpu)
                    apps = top_apps(prev_procs, procs,
                                    busy_now - prev_proc_busy,
                                    now - prev_proc_at,
                                    pkg_w, gpu_pids, gpu_w)
                prev_procs, prev_proc_at, prev_proc_busy = procs, now, busy_now

            ig = igpu()
            if ig is not None and unc_w is not None:
                # intel-rapl:0:1 "uncore" is the integrated graphics domain
                # on this part — the iGPU's own rail, not a leftover.
                ig["watts"] = round(unc_w, 3)

            bat = battery(bat_smooth)
            total = None
            source = None
            if bat and bat.get("watts"):
                # The battery gauge is the only thing that sees the whole
                # board — screen, disks, wifi and all — so it wins when the
                # machine is running on it.
                total, source = bat["watts"], "battery"
            elif psys_w is not None:
                total, source = psys_w, "psys"

            # A breakdown, not a list of readings: core and uncore come out
            # of the package figure, and whatever the platform draws beyond
            # package and dGPU is the rest. Nothing here double-counts, so
            # the bars can honestly be drawn against the total above them.
            rails = []
            if core_w is not None:
                rails.append({"key": "cores", "label": "CPU cores",
                              "watts": round(core_w, 2)})
            if unc_w is not None:
                rails.append({"key": "igpu", "label": "iGPU",
                              "watts": round(unc_w, 2)})
            if pkg_w is not None:
                rest = pkg_w - (core_w or 0.0) - (unc_w or 0.0)
                if rest > 0.05:
                    rails.append({"key": "soc", "label": "SoC + memory",
                                  "watts": round(rest, 2)})
            if gpu_w is not None:
                rails.append({"key": "dgpu", "label": "dGPU",
                              "watts": round(gpu_w, 2)})
            if total is not None:
                rest = total - sum(r["watts"] for r in rails)
                if rest > 0.05:
                    rails.append({"key": "other", "label": "Screen, disk, rest",
                                  "watts": round(rest, 2)})

            snap = {
                "ready": usage is not None,
                "cpu": {
                    "usage": usage,
                    "cores": cores,
                    "freq_mhz": cpu_freq(),
                    "temp": cpu_temp(),
                    "watts": round(pkg_w, 2) if pkg_w is not None else None,
                },
                "mem": meminfo(),
                "igpu": ig,
                "dgpu": gpu,
                "power": {
                    "total": round(total, 2) if total is not None else None,
                    "source": source,
                    "battery": bat,
                    "rails": rails,
                },
                "apps": apps,
            }
            with metrics_lock:
                metrics_state["snapshot"] = snap

            prev_cpu, prev_rapl, prev_at = cpu, energy, now
            tick += 1
            time.sleep(SAMPLE)

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
            elif self.path == "/api/metrics":
                metrics_touch()
                self.send_json(200, metrics())
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
    threading.Thread(target=sampler, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
  '';
in
{
  # RAPL's energy counters ship 0400 root:root. They are the only way to
  # see what the CPU package, its cores and the integrated GPU are actually
  # drawing — the battery gauge only reports anything while discharging, so
  # without these the panel has nothing to say about power on AC.
  #
  # The historical reason for the default mode is the 2020 PLATYPUS work:
  # a sufficiently fine-grained energy counter leaks what the CPU is doing,
  # which on a shared host is a side channel against another tenant's keys.
  # This is a single-user laptop and the group being granted the read is
  # "video", which already holds the keyboard LED and the fan controls. The
  # counters stay read-only; nothing here can write a power limit.
  #
  # udev rather than tmpfiles, because powercap is a real class and the
  # zones appear when intel_rapl_msr probes — which on this machine is after
  # systemd-tmpfiles-setup has already run. The tmpfiles rules are the
  # belt-and-braces half: they cover the zones that already exist when a
  # nixos-rebuild switch installs this without a reboot.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*", \
      RUN+="${pkgs.coreutils}/bin/chgrp video /sys/class/powercap/%k/energy_uj", \
      RUN+="${pkgs.coreutils}/bin/chmod g+r /sys/class/powercap/%k/energy_uj"
  '';

  systemd.tmpfiles.rules = [
    "z /sys/class/powercap/intel-rapl:*/energy_uj 0440 root video -"
  ];

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
      #
      # NOTE: no ProtectProc/ProcSubset either. Reading /proc/<pid>/stat for
      # every process is how the "top consumers" list is built, and hidepid
      # would reduce it to this service's own two threads.
      #
      # AF_UNIX is here for nvidia-smi, which talks to the driver over a
      # local socket. AF_INET is the listener. Nothing needs anything else.
      RestrictAddressFamilies = [ "AF_INET" "AF_UNIX" ];
    };
  };
}
