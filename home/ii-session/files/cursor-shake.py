"""Shake the pointer and it grows, so you can find it. Hyprland has no such feature.

Polls the pointer position over Hyprland's own socket and counts quick turns
in direction. Enough of them close together is a shake: the cursor is
enlarged with `setcursor` and shrunk again shortly after the shaking stops.

    ii-cursor-shake THEME SIZE [--scale N] [--hold SECONDS]

THEME and SIZE are the cursor the session normally uses. Hyprland has no way
to ask for the current one, so this is also the one place that sets it at
login (it replaces upstream's `hyprctl setcursor` line in execs.lua).
"""
import argparse
import fcntl
import os
import signal
import socket
import sys
import time
from collections import deque

# Pixels the pointer has to travel back before a turn counts. Below this is
# jitter, or the small correction at the end of a normal aim.
STROKE = 40
# This many turns inside WINDOW seconds is a shake. Aiming at something
# overshoots once or twice; three quick turns of 40px or more does not happen
# by accident.
TURNS = 3
WINDOW = 0.7
# Poll fast while the pointer moves, slowly once it has been still for a bit.
FAST, SLOW, SETTLE = 0.012, 0.05, 0.5
# `setcursor` reloads the theme on Hyprland's main thread, so every call
# freezes the whole screen for as long as it takes: ~20 ms at size 24, ~50 at
# 48, ~190 at 96 (measured here). Growing therefore jumps once, and only
# shrinking, which is cheap, is spread over a few steps.
SHRINK_STEPS, SHRINK_PAUSE = 2, 0.06


class Axis:
    """Counts reversals along one axis, with hysteresis."""

    def __init__(self):
        self.turns = deque()
        self.reset()

    def reset(self):
        self.direction = 0
        self.extreme = None
        self.turns.clear()

    def feed(self, v, now):
        if self.extreme is None:
            self.extreme = v
        elif self.direction == 0:
            if abs(v - self.extreme) >= STROKE:
                self.direction = 1 if v > self.extreme else -1
                self.extreme = v
        elif (v - self.extreme) * self.direction > 0:
            self.extreme = v
        elif abs(v - self.extreme) >= STROKE:
            self.turns.append(now)
            self.direction = -self.direction
            self.extreme = v
        while self.turns and now - self.turns[0] > WINDOW:
            self.turns.popleft()


class Detector:
    def __init__(self):
        self.axes = (Axis(), Axis())

    def feed(self, x, y, now):
        """Returns how many turns the busiest axis has made inside WINDOW."""
        for axis, v in zip(self.axes, (x, y)):
            axis.feed(v, now)
        return max(len(a.turns) for a in self.axes)

    def latest(self):
        """When the most recent counted turn happened, or None."""
        return max((a.turns[-1] for a in self.axes if a.turns), default=None)

    def reset(self):
        for axis in self.axes:
            axis.reset()


class Hyprland:
    def __init__(self):
        runtime = os.environ["XDG_RUNTIME_DIR"]
        signature = os.environ["HYPRLAND_INSTANCE_SIGNATURE"]
        self.path = f"{runtime}/hypr/{signature}/.socket.sock"

    def request(self, message):
        with socket.socket(socket.AF_UNIX) as s:
            s.connect(self.path)
            s.sendall(message.encode())
            s.shutdown(socket.SHUT_WR)
            chunks = []
            while chunk := s.recv(4096):
                chunks.append(chunk)
        return b"".join(chunks).decode()

    def position(self):
        x, y = self.request("cursorpos").split(",")
        return int(x), int(y)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("theme")
    parser.add_argument("size", type=int)
    parser.add_argument("--scale", type=float, default=4)
    parser.add_argument("--hold", type=float, default=1.0,
                        help="seconds after the last turn before it shrinks back")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    # One instance per session: a second would fight the first over the size.
    lock = open(f"{os.environ['XDG_RUNTIME_DIR']}/ii-cursor-shake.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit("ii-cursor-shake: already running")

    hypr = Hyprland()
    big = round(args.size * args.scale)
    size = args.size

    def set_size(value):
        nonlocal size
        size = value
        hypr.request(f"setcursor {args.theme} {value}")

    def grow():
        set_size(big)

    def shrink():
        start = size
        for i in range(1, SHRINK_STEPS + 1):
            t = i / SHRINK_STEPS
            eased = 1 - (1 - t) ** 2  # quick at first, then settling
            set_size(round(start + (args.size - start) * eased))
            if i < SHRINK_STEPS:
                time.sleep(SHRINK_PAUSE)

    def restore(*_):
        if size != args.size:
            set_size(args.size)
        sys.exit(0)

    signal.signal(signal.SIGTERM, restore)
    signal.signal(signal.SIGINT, restore)

    set_size(args.size)  # the login-time setcursor this replaces

    detector = Detector()
    last_pos = hypr.position()
    last_move = last_turn = time.monotonic()
    growing = False

    while True:
        now = time.monotonic()
        try:
            pos = hypr.position()
        except OSError:
            return  # Hyprland is gone

        if pos != last_pos:
            last_move = now
            last_pos = pos
            turns = detector.feed(*pos, now)
            if growing:
                # Still shaking keeps it big.
                last_turn = detector.latest() or last_turn
            elif turns >= TURNS:
                if args.verbose:
                    print(f"{now:.2f} shake at {pos}", flush=True)
                grow()
                growing = True
                last_turn = now
        elif now - last_move > SETTLE:
            detector.reset()

        if growing and now - last_turn >= args.hold:
            if args.verbose:
                print(f"{now:.2f} shrink (last turn {last_turn:.2f})", flush=True)
            shrink()
            growing = False
            detector.reset()
            last_pos = hypr.position()

        time.sleep(FAST if now - last_move < SETTLE else SLOW)


if __name__ == "__main__":
    main()
