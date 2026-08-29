# mousekeys — the numpad drives the pointer whenever NumLock is off.
#
#   NumLock OFF                        NumLock ON
#   ─────────────────────────────      ──────────────────────
#   7 8 9 / 4 6 / 1 2 3  move          the numpad, unchanged
#   5, /                 left click    (digits, / * - + . )
#   *                    middle click
#   -                    right click
#   +                    double click, held = 100 ms click train
#   0                    left button DOWN and latched (drag)
#   5, .                 release that latch (5 does this instead of clicking)
#   CTRL / SHIFT         ×3 / ×0.2 movement speed
#
# ── Why a daemon, and not one of the four obvious cheaper answers
#
#   keyd: it is already here (see ./hyprland-desktop.nix) and 2.6 does have
#   experimental pointer support — mouse1/mouse2, scrollup/scrolldown, and a
#   "keyd virtual pointer" node to emit them on. What it has no action for is
#   *relative pointer movement*, which is the whole of 7 8 9 4 6 1 2 3. It also
#   cannot see NumLock (below), and the latch/burst semantics are stateful in a
#   way keyd's macro language is not.
#
#   Hyprland binds: `movecursor` takes an absolute position, not a delta, and
#   driving it off key-repeat would move in 600 ms-then-25 Hz jerks.
#
#   X11 AccessX MouseKeys: an X server feature. There is no X server here.
#
#   ydotool per step: a process spawn (or socket round-trip) per frame at
#   120 Hz. It stays where it is, typing the clipboard.
#
# ── Why it sits downstream of keyd, and why it grabs
#
# keyd holds an exclusive EVIOCGRAB on the physical AT keyboard and re-emits
# on "keyd virtual keyboard", so nothing else can read the real one. This
# daemon therefore reads keyd's output — which also means keyd's CTRL+ESC→SUPER
# swap has already been applied by the time we see anything.
#
# It has to *grab* that node rather than merely watch it, because with NumLock
# off the numpad is not idle: the keys already mean Home ↑ PgUp ← → End ↓ PgDn,
# and 0/. already mean Insert/Delete. A listen-only design would fire Delete
# and PgUp into the focused window on every drag. So the chain is:
#
#   AT keyboard → keyd (grab) → keyd virtual kbd → mousekeys (grab)
#                                                        ├→ mousekeys virtual kbd
#                                                        └→ mousekeys virtual pointer
#
# Crash safety: the kernel drops an EVIOCGRAB when the holder dies, so a
# crashed daemon means the compositor immediately reads keyd's node again and
# the keyboard just works. Restart=always plus a systemd watchdog covers the
# worse case — a daemon that is alive but wedged, which would otherwise hold
# the grab and eat every keystroke. The watchdog ping rides the main loop, so
# it stops arriving the moment that loop stops turning.
#
# ── The feedback loop this would otherwise have
#
# keyd's `ids = [ "*" ]` matches every device it identifies as a keyboard —
# including this daemon's own virtual keyboard. keyd would grab it, re-emit it
# on the node this daemon reads, and each keystroke would circulate forever.
# The `-feed:0001` exclusion in ./hyprland-desktop.nix is what prevents that;
# the two vendor:product pairs are load-bearing and must stay in sync with
# KBD_VENDOR/KBD_PRODUCT in the daemon below.
#
# ── NumLock is an LED, not a keycode
#
# The kernel emits KEY_KP5 whether or not NumLock is engaged; the digit/arrow
# distinction is made in xkb, downstream of everything evdev can see. What is
# observable is the LED the compositor writes back onto the keyboard it reads —
# which, once we are grabbing, is our own virtual one. So the daemon asks its
# own device node (EVIOCGLED) rather than trying to infer the state. If that
# read ever fails it assumes NumLock is ON, i.e. it stops claiming keys, which
# is the harmless direction to be wrong in.
{ config, pkgs, ... }:

let
  daemon = pkgs.writeText "mousekeysd.py" ''
    # mousekeysd - numpad-driven pointer control.
    #
    # Sits downstream of keyd: it grabs the "keyd virtual keyboard" node,
    # forwards every event to a virtual keyboard of its own, and while NumLock
    # is OFF it swallows the twelve numpad keys and turns them into pointer
    # events on a second, virtual mouse.
    #
    # See modules/mousekeys.nix for why it is shaped this way.

    import math
    import os
    import select
    import signal
    import socket
    import sys
    import time

    from evdev import InputDevice, UInput, ecodes as ec, list_devices

    # --- identity ---------------------------------------------------------------
    #
    # The vendor:product pair below is NOT cosmetic. keyd matches "*" against
    # every device it considers a keyboard, so without the matching exclusion in
    # modules/hyprland-desktop.nix keyd would grab this daemon's own virtual
    # keyboard and re-emit it into the node this daemon reads -> infinite loop.
    KBD_NAME = "mousekeys virtual keyboard"
    PTR_NAME = "mousekeys virtual pointer"
    KBD_VENDOR, KBD_PRODUCT = 0xFEED, 0x0001
    PTR_VENDOR, PTR_PRODUCT = 0xFEED, 0x0002

    # Read the keyboard as it comes OUT of keyd, so keyd's CTRL+ESC swap has
    # already been applied. The AT node is the fallback for a keyd-less system;
    # keyd holds an exclusive grab on it whenever keyd is running, so it can only
    # ever be reached when keyd is not.
    SOURCE_NAMES = ("keyd virtual keyboard", "AT Translated Set 2 keyboard")

    # --- tuning -----------------------------------------------------------------
    SPEED = 900.0          # px/s, flat: no acceleration ramp
    CTRL_FACTOR = 3.0      # CTRL held -> 2700 px/s
    SHIFT_FACTOR = 0.2     # SHIFT held -> 180 px/s
    TICK = 1.0 / 120.0     # pointer update rate
    MAX_DT = 0.05          # never integrate more than this in one step

    # KP_PLUS emits a click train at CLICK_PERIOD. A tap therefore yields two
    # clicks 100 ms apart -- comfortably inside every toolkit's double-click
    # window -- and a hold just keeps the train running.
    CLICK_PERIOD = 0.100
    CLICK_DOWN = 0.040
    MIN_BURST_CLICKS = 2

    WATCHDOG_PERIOD = 3.0
    LED_CACHE = 0.05

    # --- key map ----------------------------------------------------------------
    MOVE = {
        ec.KEY_KP7: (-1, -1), ec.KEY_KP8: (0, -1), ec.KEY_KP9: (1, -1),
        ec.KEY_KP4: (-1, 0),                       ec.KEY_KP6: (1, 0),
        ec.KEY_KP1: (-1, 1),  ec.KEY_KP2: (0, 1),  ec.KEY_KP3: (1, 1),
    }
    HOLD_BTN = {
        ec.KEY_KP5: ec.BTN_LEFT,
        ec.KEY_KPSLASH: ec.BTN_LEFT,
        ec.KEY_KPASTERISK: ec.BTN_MIDDLE,
        ec.KEY_KPMINUS: ec.BTN_RIGHT,
    }
    KEY_BURST = ec.KEY_KPPLUS      # tap: double click. hold: 100 ms click train.
    KEY_LATCH = ec.KEY_KP0         # press: left button down and STAYS down.
    KEY_UNLATCH = ec.KEY_KPDOT     # press: release whatever the latch is holding.

    # Keys that drop the KP0 latch instead of doing their usual job. KP_DOT
    # exists only for this. KP5 is here because the finger is already on it,
    # and a left "click" while the left button is latched down is not a
    # meaningful thing to ask for -- the refcount would simply hand the button
    # from the latch over to KP5 and carry the drag on until KP5 came back up.
    LATCH_RELEASERS = {KEY_UNLATCH, ec.KEY_KP5}

    CLAIMED = set(MOVE) | set(HOLD_BTN) | {KEY_BURST, KEY_LATCH} | LATCH_RELEASERS

    CTRL_KEYS = {ec.KEY_LEFTCTRL, ec.KEY_RIGHTCTRL}
    SHIFT_KEYS = {ec.KEY_LEFTSHIFT, ec.KEY_RIGHTSHIFT}

    # Event types deliberately NOT copied onto the forwarding keyboard.
    #   EV_SYN / EV_FF   - uinput handles or rejects these itself.
    #   EV_REP           - if this device advertised it, the kernel would generate
    #                      a second set of autorepeats on top of the ones already
    #                      arriving from the source. Forwarded value==2 events pass
    #                      through fine without it.
    #   EV_MSC           - MSC_SCAN precedes each key in its own SYN batch; dropping
    #                      the type outright is simpler than pairing scancodes with
    #                      the keys we swallow, and nothing downstream needs them.
    FILTERED_TYPES = (ec.EV_SYN, ec.EV_FF, ec.EV_FF_STATUS, ec.EV_REP, ec.EV_MSC)


    def log(msg):
        print("[mousekeysd] " + msg, file=sys.stderr, flush=True)


    class Notify:
        """Minimal sd_notify, so the unit can be Type=notify with a watchdog."""

        def __init__(self):
            addr = os.environ.get("NOTIFY_SOCKET")
            self.sock = None
            if not addr:
                return
            self.addr = "\0" + addr[1:] if addr.startswith("@") else addr
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)

        def send(self, msg):
            if self.sock is None:
                return
            try:
                self.sock.sendto(msg.encode(), self.addr)
            except OSError:
                pass


    class Pointer:
        """The virtual mouse. Buttons are refcounted by holder.

        BTN_LEFT can be claimed by KP5, KP_SLASH, the KP0 latch and the KP_PLUS
        click train at the same time; releasing one holder must not lift a button
        another one is still holding.
        """

        def __init__(self):
            self.ui = UInput(
                {
                    ec.EV_KEY: [ec.BTN_LEFT, ec.BTN_RIGHT, ec.BTN_MIDDLE],
                    ec.EV_REL: [ec.REL_X, ec.REL_Y],
                },
                name=PTR_NAME, vendor=PTR_VENDOR, product=PTR_PRODUCT, phys="mousekeys",
            )
            self.holders = {ec.BTN_LEFT: set(), ec.BTN_RIGHT: set(), ec.BTN_MIDDLE: set()}

        def press(self, btn, who):
            holders = self.holders[btn]
            if not holders:
                self.ui.write(ec.EV_KEY, btn, 1)
                self.ui.syn()
            holders.add(who)

        def release(self, btn, who):
            holders = self.holders[btn]
            if who not in holders:
                return
            holders.discard(who)
            if not holders:
                self.ui.write(ec.EV_KEY, btn, 0)
                self.ui.syn()

        def release_all(self):
            lifted = False
            for btn, holders in self.holders.items():
                if holders:
                    holders.clear()
                    self.ui.write(ec.EV_KEY, btn, 0)
                    lifted = True
            if lifted:
                self.ui.syn()

        def move(self, dx, dy):
            if not dx and not dy:
                return
            if dx:
                self.ui.write(ec.EV_REL, ec.REL_X, dx)
            if dy:
                self.ui.write(ec.EV_REL, ec.REL_Y, dy)
            self.ui.syn()

        def close(self):
            self.release_all()
            self.ui.close()


    class Daemon:
        def __init__(self):
            self.notify = Notify()
            self.pointer = Pointer()
            self.src = None
            self.kbd = None

            self.claimed_held = set()   # numpad keys we swallowed the press of
            self.unlatched = set()      # keys whose press went to dropping the latch
            self.moving = set()         # subset of MOVE currently held
            self.ctrl = set()
            self.shift = set()

            self.acc_x = 0.0
            self.acc_y = 0.0
            self.last_move = 0.0
            self.next_move = 0.0

            self.burst_running = False  # click train alive
            self.burst_held = False     # KP_PLUS still physically down
            self.burst_clicks = 0
            self.burst_down = False
            self.next_burst = 0.0

            self._led = True            # fail safe: assume NumLock ON == passthrough
            self._led_at = 0.0
            self._led_warned = False

        # --- device plumbing ---------------------------------------------------

        def acquire(self):
            """Find the source keyboard, mirror its capabilities, then grab it."""
            src = None
            candidates = {}
            for path in list_devices():
                try:
                    dev = InputDevice(path)
                except OSError:
                    continue
                if dev.name in SOURCE_NAMES and dev.name not in candidates:
                    candidates[dev.name] = dev
                else:
                    dev.close()
            for name in SOURCE_NAMES:
                if name in candidates:
                    src = candidates.pop(name)
                    break
            for dev in candidates.values():
                dev.close()
            if src is None:
                return False

            # Create the replacement BEFORE grabbing, and give the compositor a
            # moment to open it. The other order leaves a window with no keyboard.
            kbd = UInput.from_device(
                src, filtered_types=FILTERED_TYPES,
                name=KBD_NAME, vendor=KBD_VENDOR, product=KBD_PRODUCT, phys="mousekeys",
            )
            time.sleep(0.5)
            try:
                src.grab()
            except OSError as err:
                log("cannot grab %s: %s" % (src.path, err))
                kbd.close()
                src.close()
                return False

            self.src, self.kbd = src, kbd
            log("attached to %s (%s)" % (src.name, src.path))
            return True

        def release_source(self):
            self.reset()
            self.claimed_held.clear()
            if self.src is not None:
                try:
                    self.src.ungrab()
                except OSError:
                    pass
                self.src.close()
                self.src = None
            if self.kbd is not None:
                self.kbd.close()
                self.kbd = None

        # --- NumLock -----------------------------------------------------------

        def numlock_on(self, now):
            """NumLock is an LED, not a keycode.

            The kernel sends KEY_KP5 whether or not NumLock is engaged -- the
            distinction lives entirely in xkb, and surfaces to us as the LED state
            the compositor writes back onto the keyboard it is reading, which is
            this daemon's own virtual one.
            """
            if now - self._led_at < LED_CACHE:
                return self._led
            self._led_at = now
            dev = getattr(self.kbd, "device", None)
            if dev is None:
                if not self._led_warned:
                    log("no node for the virtual keyboard; NumLock state unreadable")
                    self._led_warned = True
                self._led = True
                return self._led
            try:
                led = ec.LED_NUML in dev.leds()
            except OSError:
                led = True
            if led != self._led:
                # Logged on every flip: this is the one piece of state that
                # decides whether the numpad is a pointer, and it is inferred
                # rather than told to us, so `journalctl -u mousekeys` should
                # be able to answer "what does the daemon think right now".
                log("NumLock %s: numpad %s"
                    % ("on" if led else "off",
                       "passes through" if led else "drives the pointer"))
            self._led = led
            return self._led

        def reset(self):
            """Drop every pointer action. claimed_held is deliberately kept: the
            key-up events for keys whose press we ate still have to be eaten."""
            self.moving.clear()
            self.unlatched.clear()
            self.acc_x = self.acc_y = 0.0
            self.burst_running = False
            self.burst_held = False
            self.burst_down = False
            self.burst_clicks = 0
            self.pointer.release_all()

        # --- input handling ----------------------------------------------------

        def handle(self, event, now):
            if event.type == ec.EV_MSC:
                return
            if event.type == ec.EV_KEY:
                if event.value != 2:
                    held = event.value == 1
                    for keys, state in ((CTRL_KEYS, self.ctrl), (SHIFT_KEYS, self.shift)):
                        if event.code in keys:
                            state.add(event.code) if held else state.discard(event.code)
                if event.code in CLAIMED:
                    if event.value == 1 and not self.numlock_on(now):
                        self.claimed_held.add(event.code)
                        self.key_down(event.code, now)
                        return
                    if event.value == 0 and event.code in self.claimed_held:
                        self.claimed_held.discard(event.code)
                        self.key_up(event.code)
                        return
                    if event.value == 2 and event.code in self.claimed_held:
                        return
            self.kbd.write_event(event)

        def key_down(self, code, now):
            if code in LATCH_RELEASERS and "latch" in self.pointer.holders[ec.BTN_LEFT]:
                self.pointer.release(ec.BTN_LEFT, "latch")
                self.unlatched.add(code)
                return
            if code in MOVE:
                if not self.moving:
                    self.last_move = now
                    self.next_move = now + TICK
                    self.acc_x = self.acc_y = 0.0
                self.moving.add(code)
            elif code in HOLD_BTN:
                self.pointer.press(HOLD_BTN[code], code)
            elif code == KEY_LATCH:
                self.pointer.press(ec.BTN_LEFT, "latch")
            elif code == KEY_BURST:
                self.burst_held = True
                if not self.burst_running:
                    self.burst_running = True
                    self.burst_clicks = 0
                    self.burst_down = False
                    self.next_burst = now

        def key_up(self, code):
            if code in self.unlatched:
                # Its press went to dropping the latch, so the release does nothing.
                self.unlatched.discard(code)
                return
            if code in MOVE:
                self.moving.discard(code)
                if not self.moving:
                    self.acc_x = self.acc_y = 0.0
            elif code in HOLD_BTN:
                self.pointer.release(HOLD_BTN[code], code)
            elif code == KEY_BURST:
                # The train keeps going until it has emitted its two clicks, so a
                # tap shorter than the double-click still produces a double-click.
                self.burst_held = False

        # --- timed work --------------------------------------------------------

        def step_move(self, now):
            dt = min(now - self.last_move, MAX_DT)
            self.last_move = now
            vx = vy = 0
            for code in self.moving:
                dx, dy = MOVE[code]
                vx += dx
                vy += dy
            if vx or vy:
                # Normalise, or a diagonal would travel sqrt(2) times too fast.
                mag = math.hypot(vx, vy)
                speed = SPEED
                if self.ctrl:
                    speed *= CTRL_FACTOR
                if self.shift:
                    speed *= SHIFT_FACTOR
                self.acc_x += vx / mag * speed * dt
                self.acc_y += vy / mag * speed * dt
                ix, iy = math.trunc(self.acc_x), math.trunc(self.acc_y)
                self.acc_x -= ix
                self.acc_y -= iy
                self.pointer.move(ix, iy)
            self.next_move = now + TICK

        def step_burst(self, now):
            if self.burst_down:
                self.pointer.release(ec.BTN_LEFT, "burst")
                self.burst_down = False
                if not self.burst_held and self.burst_clicks >= MIN_BURST_CLICKS:
                    self.burst_running = False
                    return
                self.next_burst = now + (CLICK_PERIOD - CLICK_DOWN)
                return
            if not self.burst_held and self.burst_clicks >= MIN_BURST_CLICKS:
                self.burst_running = False
                return
            self.pointer.press(ec.BTN_LEFT, "burst")
            self.burst_down = True
            self.burst_clicks += 1
            self.next_burst = now + CLICK_DOWN

        # --- main loop ---------------------------------------------------------

        def run(self):
            self.notify.send("READY=1")
            next_watchdog = 0.0
            while True:
                now = time.monotonic()
                if now >= next_watchdog:
                    self.notify.send("WATCHDOG=1")
                    next_watchdog = now + WATCHDOG_PERIOD

                if self.src is None:
                    if not self.acquire():
                        time.sleep(1.0)
                        continue
                    now = time.monotonic()

                # NumLock coming back on mid-drag has to tear the drag down.
                if self.numlock_on(now) and (self.moving or self.burst_running
                                             or any(self.pointer.holders.values())):
                    self.reset()

                deadlines = [next_watchdog]
                if self.moving:
                    deadlines.append(self.next_move)
                if self.burst_running:
                    deadlines.append(self.next_burst)
                timeout = max(0.0, min(deadlines) - time.monotonic())

                try:
                    readable, _, _ = select.select([self.src.fd], [], [], timeout)
                except InterruptedError:
                    continue
                except OSError:
                    self.release_source()
                    continue

                if readable:
                    try:
                        for event in self.src.read():
                            self.handle(event, time.monotonic())
                    except OSError:
                        # keyd restarted and took its virtual node with it.
                        log("source device went away; re-acquiring")
                        self.release_source()
                        continue

                now = time.monotonic()
                if self.moving and now >= self.next_move:
                    self.step_move(now)
                if self.burst_running and now >= self.next_burst:
                    self.step_burst(now)

        def shutdown(self):
            self.release_source()
            self.pointer.close()


    def main():
        daemon = Daemon()

        def bye(signum, frame):
            raise SystemExit(0)

        signal.signal(signal.SIGTERM, bye)
        signal.signal(signal.SIGINT, bye)
        try:
            daemon.run()
        finally:
            daemon.shutdown()


    main()
  '';
in
{
  # /dev/uinput at 0660 root:uinput, and the module loaded at boot rather than
  # on first open. The service below joins that group.
  hardware.uinput.enable = true;

  systemd.services.mousekeys = {
    description = "Numpad pointer control (mousekeys)";
    wantedBy = [ "multi-user.target" ];

    # keyd owns the device this reads, and destroys its virtual node on
    # restart. The daemon re-acquires on its own (it has to: the node appears
    # asynchronously after keyd starts), but tying the units together means a
    # `systemctl restart keyd` does not leave a stale grab behind.
    after = [ "keyd.service" ];
    partOf = [ "keyd.service" ];

    serviceConfig = {
      ExecStart = "${pkgs.python3.withPackages (ps: [ ps.evdev ])}/bin/python3 ${daemon}";

      # Type=notify + WatchdogSec is the point of the sd_notify code in the
      # daemon: a wedged process holding an input grab is worse than a dead
      # one, so systemd has to be able to tell the difference.
      Type = "notify";
      WatchdogSec = 10;
      Restart = "always";
      RestartSec = 1;

      DynamicUser = true;
      SupplementaryGroups = [
        "input" # read/grab /dev/input/event*
        "uinput" # create the virtual keyboard and pointer
      ];
      DeviceAllow = [ "/dev/uinput rw" "char-input rw" ];
      DevicePolicy = "closed";

      # hardening — this reads every keystroke on the machine, so it gets no
      # network, no filesystem, and no ability to look at other processes.
      CapabilityBoundingSet = "";
      IPAddressDeny = "any";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateNetwork = true;
      PrivateTmp = true;
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProtectSystem = "strict";
      RestrictAddressFamilies = [ "AF_UNIX" ]; # sd_notify only
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
      UMask = "0077";
    };
  };
}
