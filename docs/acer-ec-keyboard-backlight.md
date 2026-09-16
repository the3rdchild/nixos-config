# Acer EC keyboard backlight — brightness & colour

The keyboard backlight on this Aspire A715-59G is driven by the in-tree
`acer_ec_kbd` kernel module, part of the [acer-ec driver
tree](../Reference/acer-aspire-A715-79G/acer-ec). It talks to the ITE embedded
controller directly, with no `ec_sys`, no `fnkey.exe`, and no vendor daemon.

This documents how colour works, why the machine turned red on its own, and how
to change or debug it.

---

## TL;DR

```fish
# colour is a standard multicolor LED — plain R G B, each 0-255
echo "0 0 255" > /sys/class/leds/acer_ec::kbd_backlight/multi_intensity   # blue
echo "255 0 0" > /sys/class/leds/acer_ec::kbd_backlight/multi_intensity   # red

# brightness, unchanged
brightnessctl -d acer_ec::kbd_backlight set 50%
```

Both files are writable by the `video` group — no root needed. The boot-time
colour is declared in Nix, not in EC state:

```nix
# modules/acer-ec.nix
kbdColour = "0 0 255";   # "R G B", or null to leave the EC's colour alone
```

---

## Why it went red by itself

This is the question that started it. The colour was blue, a rebuild happened,
and afterwards it was red — but **nothing in the build changed it**.

Colour is **EC-resident state**. The chip holds it; before this driver work,
nothing on the Linux side ever wrote it. So it kept whatever was last set —
by Acer Control Center under Windows, or a previous boot — and survived warm
reboots. But when the EC actually **loses power**, it resets to the firmware
default, which on this unit is red.

The rebuild only *coincided* with the change: a rebuild meant a reboot, and
somewhere around there the EC lost power and reverted. The fix is to stop
relying on EC state and set the colour declaratively on every boot (see
`kbdColour` above), so it survives power cycles.

---

## Protocol

The EC lighting opcode is `0xCA`. The `FDAT` byte selects what the rest of the
mailbox means:

| FDAT     | meaning    | payload                                         |
| -------- | ---------- | ----------------------------------------------- |
| `0x06` | brightness | `FBUF` = level `0x00`–`0xFF`             |
| *zone* | colour     | `FBUF..FBF2` = colour bytes, `FBF3` = flags |

Mailbox registers, in the EC SystemMemory region (see the [RE
report](../Reference/acer-aspire-A715-79G/acer-ec/docs/reverse-engineering.md)):

| Register | Offset   | Colour byte                                    |
| -------- | -------- | ---------------------------------------------- |
| `FCMD` | `0xF8` | `0xCA` (written last — this is the trigger) |
| `FDAT` | `0xF9` | zone                                           |
| `FBUF` | `0xFA` | **Blue**                                 |
| `FBF1` | `0xFB` | **Red**                                  |
| `FBF2` | `0xFC` | **Green**                                |
| `FBF3` | `0xFD` | flags (`0x00`)                               |

### The byte order is not R,G,B

Note `FBF1`=Red and `FBF2`=Green — **green and red are swapped** relative to
what the register order suggests. This was the one genuinely ambiguous part.

The reference [Acer-Aspire-A715-79G-KeyBoard][ref] project ships **two
contradictory answers**: its README table says `FA=Blue, FB=Red, FC=Green`,
while its `rgb.sh` writes blue, green, red. The README even flags its own
disagreement.

We settled it by measurement on this unit: with the driver following `rgb.sh`'s
`B,G,R` order, writing `0 255 0` (green) lit the keyboard **red**. That puts red
on `FBF1` and green on `FBF2` — i.e. the **README table is correct** and
`rgb.sh` is wrong.

The driver now presents the standard multicolor `R G B` order on
`multi_intensity` and does the swap internally.

> **Different units may differ.** This was confirmed on one A715-59G. If your
> colours come out crossed, see debugging below.

[ref]: ../Reference/acer-aspire-A715-79G/Acer-Aspire-A715-79G-KeyBoard
### Zones

The colour command addresses a **zone** via `FDAT`. Zone `3` works here, but
`fnkey.exe` picks the zone from a runtime keyboard-type probe, so it is not
guaranteed to be `3` on every unit. It is a module parameter, not a constant:

```fish
sudo modprobe -r acer_ec_kbd
sudo modprobe acer_ec_kbd zone=1
```

---

## How the driver implements it

[`src/acer_ec_kbd.c`](../Reference/acer-aspire-A715-79G/acer-ec/src/acer_ec_kbd.c)
registers a **multicolor LED** (`led_classdev_mc`), so colour lands on the
kernel-standard `multi_intensity` attribute rather than a bespoke one.

Three design points worth knowing:

- **It goes through `ec_core_ecmd()`, not `ec_sys`/debugfs** like the reference
  `rgb.sh` does. That serialises colour writes against fan control under the
  shared `ecmd_lock`, and avoids needing `ec_sys write_support=1` — which would
  expose raw EC writes to every root process, on a chip that also owns the
  thermal loop.
- **The colour command is skipped while `multi_intensity` is `0 0 0`.** A module
  nobody has written a colour to behaves exactly like the old brightness-only
  one: the EC keeps whatever colour it already had. Without this, the first
  brightness keypress after boot would overwrite the colour with the driver's
  initial value. All-zero is a safe sentinel because it is indistinguishable
  from off, which brightness already covers.
- **The LED keeps the name `acer_ec::kbd_backlight`** rather than the
  `acer_ec:rgb:kbd_backlight` the naming convention suggests, because the
  `SUPER+CTRL+↑/↓` binds and `acer-kbd-toggle` all address it by name.

Because writing `multi_intensity` re-runs the brightness callback, the colour
reaches the EC on write without needing a brightness change to flush it. And
`LED_CORE_SUSPENDRESUME` re-sends both across suspend, since they leave the EC
otherwise.

---

## The NixOS integration

[`modules/acer-ec.nix`](../modules/acer-ec.nix):

- **`kbdColour`** — `"R G B"` seeded onto `multi_intensity` by a udev rule on
  device add, so the colour is re-applied every boot and survives EC power loss.
  `null` disables the seed and restores brightness-only behaviour.
- The udev rule also gives `multi_intensity` the same **`video`-group
  read/write** permissions the brightness file already had, so colour is
  settable without root — the same group the keybinds rely on.

```
ACTION=="add", SUBSYSTEM=="leds", KERNEL=="acer_ec::kbd_backlight", \
  ATTR{multi_intensity}="0 0 255", \
  RUN+="… chgrp video …/multi_intensity", \
  RUN+="… chmod g+w …/multi_intensity", \
  …
```

---

## Debugging

**Colours come out wrong (e.g. `255 0 0` isn't red).** The byte order or zone
differs on your unit. Write a pure primary and note what lights:

```fish
echo "255 0 0" > /sys/class/leds/acer_ec::kbd_backlight/multi_intensity
```

- Lights a *different colour* → byte order differs. The swap lives in
  `kbd_brightness_set()` in `acer_ec_kbd.c`, in the three `buf[…] = kbd_subled[…]` lines.
- *Nothing lights* → wrong zone. Reload with `zone=0`…`zone=5` (see Zones).

**Colour doesn't stick after reboot.** Confirm the udev seed ran:

```fish
cat /sys/class/leds/acer_ec::kbd_backlight/multi_intensity   # should match kbdColour
udevadm test /sys/class/leds/acer_ec::kbd_backlight 2>&1 | grep multi_intensity
```

**Module didn't load.** It is a kernel module — colour changes need a real
reboot (or `modprobe -r`/`modprobe`), not just `nixos-rebuild switch`.

```fish
lsmod | grep acer_ec_kbd
modinfo acer_ec_kbd | grep -E 'version|parm'   # version 0.2 has colour
```

---

## What this does *not* do

- **No per-key or effects** (breathing, wave, etc.). This is a single-zone
  static backlight; the EC exposes one colour for the whole keyboard.
- **No timeout / auto-off.** Acer Control Center offers one under Windows; it is
  not wired up here. Brightness + `acer-kbd-toggle` cover on/off.

---

## See also

- [`reverse-engineering.md`](../Reference/acer-aspire-A715-79G/acer-ec/docs/reverse-engineering.md)
  — the full EC/DSDT/WMI reverse-engineering report (fan control, SCMD/ECMD
  protocol, memory map).
- [Acer-Aspire-A715-79G-KeyBoard][ref] — the userspace `ec_sys` reference this
  colour work is based on. **Its `rgb.sh` byte order is wrong** (see above); its
  README table is right.
