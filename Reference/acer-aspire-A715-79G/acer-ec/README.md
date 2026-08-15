# acer-ec — Acer EC communication framework

[!CAUTION]
> **This is experimental software.** Writing incorrect values can overheat your
> laptop. Fan 1 (CPU) duty writes are honoured indefinitely on this firmware —
> a low value stops the CPU fan and nothing puts it back. Use at your own risk.

## Supported hardware

- **Laptop** — Acer Aspire A715-79G (i7-13620H, RTX 3050)
- **EC** — ITE 8222 (ACPI EC at `0x62/0x66`)
- **ACPI WMI** — 3 GUIDs (ABBC0F6B, ABBC0F6C, ABBC0F6D)

Likely compatible with any Acer/Nitro/Predator laptop built on the same EC
firmware platform. Tested on **Fedora 44** with kernel **6.14.x**.

## What it does

| Sysfs file | Access | Description |
|---|---|---|
| `profile` | RW (1-4) | Fan profile: 1=quiet, 2=balanced, 3=performance, 4=gaming |
| `fan1_duty` | RO | Fan 1 duty cycle (0-255), EC-managed |
| `fan2_duty` | RO | Fan 2 duty cycle (0-255) |
| `fan1_rpm` | RO | Fan 1 speed (real RPM) |
| `fan2_rpm` | RO | Fan 2 speed (real RPM) |
| `fan3_rpm` | RO | Always 0 (unused slot) |
| `fan4_rpm` | RO | Always 0 (unused slot) |
| `fan1_duty_set` | WO | Write Fan 1 duty (0-255) — **dangerous, see Limitations** |
| `fan2_duty_set` | WO | Write Fan 2 duty (0-255, e.g. `echo 0 > fan2_duty_set`) |
| `fan_auto` | WO | Hand both fans back to the EC curve (any value) |
| `tmp_temp` | RO | ACPI temperature (°C) |
| `dthl_val` | RO | Throttle level (bitmask) |
| `dtbp_val` | RO | Turbo boost power band |
| `airp_val` | RO | Airplane / temperature band |
| `winf_val` | RO | Windows interface flags |
| `rinf_val` | RO | Radio info flags |
| `all` | RO | One-shot dump of all values |

### Examples

```bash
# Set balanced profile
echo 2 > /sys/kernel/acer_fanctl/profile

# Set GPU fan to 100% (max)
echo 255 > /sys/kernel/acer_fanctl/fan2_duty_set

# Stop GPU fan (0% duty, fan coasts)
echo 0 > /sys/kernel/acer_fanctl/fan2_duty_set

# Give both fans back to the EC curve
echo 1 > /sys/kernel/acer_fanctl/fan_auto

# Read everything
cat /sys/kernel/acer_fanctl/all
```

## Architecture

Two kernel modules, loaded in order:

```
acer_ec_core.ko      # infrastructure — ioremap + ACPI handle
    ↓ depends
acer_fanctl.ko       # consumer — sysfs interface
```

- `acer_ec_core` exports `ec_core_read8`, `ec_core_read16`, `ec_core_scmd`
- `acer_fanctl` uses the core API, never touches hardware directly
- Future modules (keyboard backlight, battery limits) can also use the core

## Install

```bash
git clone https://github.com/YOUR_USER/acer-ec.git
cd acer-ec
chmod +x install.sh
sudo ./install.sh
```

### Manual rebuild after kernel update

```bash
sudo make -C /lib/modules/$(uname -r)/build M=$(pwd) clean modules
sudo make modules_install INSTALL_MOD_PATH=/
sudo depmod -a
sudo modprobe -r acer_fanctl acer_ec_core
sudo modprobe acer_fanctl
```

Or install via DKMS:

```bash
sudo dkms add .
sudo dkms install acer-ec/0.1
```

## Uninstall

```bash
sudo ./uninstall.sh
```

## Files

```
acer-ec/
├── src/
│   ├── acer_ec_core.c
│   ├── acer_ec_core.h
│   └── acer_fanctl.c
├── dkms.conf
├── Makefile
├── install.sh
├── uninstall.sh
├── LICENSE              (GPL-2.0)
├── README.md
└── docs/
    └── reverse-engineering.md
```

## Limitations

- **Fan 1 (CPU) writes are not reverted by the EC.** Earlier revisions of this
  README claimed the firmware overwrites DUT1 within ~500ms. That is not true on
  the A715-79G: a duty written to fan 1 is honoured until something releases it.
  Writing 0 stops the CPU fan and it stays stopped. Prefer `profile` switching
  for CPU fan control, and keep `fan1_duty_set` root-only.
- **SCMD 0x68 carries both duties at once.** byte0 is DUT1, byte1 is DUT2, and
  there is no "leave this one alone" encoding. Both duty stores therefore read
  the sibling fan's current duty out of EC RAM and re-send it unchanged. Before
  this was fixed, `echo 255 > fan2_duty_set` also stopped the CPU fan.
- **Manual duty is sticky, and only a profile CHANGE clears it.** Once a duty is
  written, that fan stays manual until the EC re-asserts its curve — and it only
  does that when the profile value actually changes. Re-sending the profile that
  is already active is a no-op. `fan_auto` handles this by bouncing through a
  neighbouring profile and back; writing `profile` clears it only if the value
  differs from the current one.
- **No `dracut --force` needed.** Modules are loaded after rootfs via
  `modules-load.d`. Initramfs inclusion is unnecessary.
- **RPM values** are converted from raw tachometer periods. Formula:
  `RPM = 60,000,000 / raw`. Raw values ~40000 → ~1500 RPM.

## CLI

The `install.sh` script copies a `acer-ec` command to `/usr/local/bin`:

```bash
acer-ec                    # show status (default)
acer-ec status             # pretty-print fan/temp values
acer-ec profile            # show profile help
acer-ec profile gaming     # set profile by name
acer-ec profile 4          # set profile by number
```

Profile names: `quiet` (1), `balanced` (2), `performance` (3), `gaming` (4).

## License

GNU General Public License v2.0 — see [LICENSE](LICENSE).
