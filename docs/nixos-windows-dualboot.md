# NixOS + Windows dual-boot

Adding Windows alongside NixOS on the **Phison 500G NVMe** — the disk that holds
NixOS root `/`, the ESP, and swap. NixOS stays the default boot; Windows is
installed into ~60G freed by shrinking the existing ext4 root.

This guide is specific to this machine — see the **Target layout** section for
why most of the generic NixOS-wiki complexity does not apply here.

> ## ⚠️ CRITICAL — NVMe names are NOT stable on this machine
>
> On this Acer the kernel assigns `nvme0n1` / `nvme1n1` by enumeration order,
> which **changes between boots**. During this very investigation the Phison
> disk showed up as `nvme0n1` in one reading and `nvme1n1` in the next.
>
> **Never** target a disk by its `nvmeXn1` name. Always identify by
> **model + size**:
>
> | Physical disk | Model | Size | Role |
> |---|---|---|---|
> | the NixOS disk | **Phison ESO512GHLCA1-E9C** | 476.9G (500G) | ESP + ext4 root + swap |
> | the data disk | **TEAM TM8FP6256G** | 238.5G (256G) | NTFS at `/mnt/doc` |
>
> Before any `resize2fs` / `parted` command, run `lsblk -o NAME,MODEL,SIZE` and
> confirm the model on the disk you're about to touch. Hitting the TEAM data
> disk by name would damage your `/mnt/doc` data.

---

## Target layout

On the **Phison 500G** disk (whatever `nvmeXn1` it is at boot time):

```
Phison 500G  (GPT, UEFI)
├── p1  vfat   ~1G     ESP @ /boot    systemd-boot + Windows bootloader (shared)
├── p2  ext4   ~407G   NixOS /        (shrunk from 467G by ~60G)
├── ──  (freed ~60G) → Windows: MSR + recovery + NTFS
└── p3  swap   8.8G                   (already at end of disk)
```

The **TEAM 256G** disk (NTFS, `/mnt/doc`) stays as-is — shared data, untouched
by the resize. Note Windows ends up *between* the NixOS root and the swap
> partition, which is harmless.

### Why this is the easy case

| Generic NixOS-wiki complication | Applies here? | Why not |
|---|---|---|
| XBOOTLDR (ESP too small) | ❌ | ESP is 1G with 742M free |
| edk2-uefi-shell (Windows on a *different* ESP) | ❌ | Windows + systemd-boot share one ESP |
| GRUB `os-prober` / manual chainload | ❌ | We use systemd-boot, which autodetects |
| Reconfiguring the bootloader in NixOS | ❌ | `modules/bootloader.nix` already correct |

systemd-boot reads the ESP at boot time. When Windows writes
`/EFI/Microsoft/Boot/bootmgfw.efi` to the **same** ESP, systemd-boot shows a
"Windows Boot Manager" entry automatically. No `nixos-rebuild` required for the
bootloader at any point.

---

## Prerequisites

- **Windows ISO** (10 or 11).
- **One USB flash drive (≥8G)** — reused sequentially. See **Single-USB flow**
  below; you do not need two USBs.
- **NixOS live USB image** (the one this OS was installed from) — for the
  offline ext4 shrink. **Root cannot be shrunk while mounted.**
- **Backup** of anything irreplaceable. Resize is safe but not risk-free.

### Single-USB flow (only one USB drive)

The two uses of the USB are **sequential**, never simultaneous, so one USB is
fine. Plan:

1. **Phase A (shrink):** Flash the USB as the **NixOS live USB** → boot it →
   shrink `p2` → reboot to running NixOS.
2. **Phase B (Windows installer):** From running NixOS, reflash the **same USB**
   with **Ventoy** and drop the Windows ISO on it → boot it → install Windows.

So the USB changes identity twice: live-NixOS → Ventoy/Windows. Never both at
once.

> **Before Phase B**, make sure the **Windows ISO is already on the NixOS disk**
> (download from microsoft.com, ~5G). Once you reflash the USB as Ventoy, the
> NixOS installer that was on it is gone — but you don't need it anymore.

---

## Stage 0 — Pre-flight checks (from running NixOS)

Run these now, save the output. You'll compare against them after the whole
operation.

```fish
# Confirm layout & ESP free space — identify disks by MODEL, never by nvme name
lsblk -o NAME,MODEL,FSTYPE,FSAVAIL,SIZE,MOUNTPOINTS

# Confirm boot mode + current bootloader
bootctl status | head -5

# efibootmgr is NOT installed on this NixOS by default. Use a nix-shell for it:
nix-shell -p efibootmgr -c 'efibootmgr -v'

# Snapshot the ESP contents (so we can verify Windows didn't clobber it)
ls -la /boot/EFI/
```

Expected (this machine, confirmed 2026-07):
- Boot mode = UEFI, Secure Boot = off.
- **Phison ESO512GHLCA1-E9C** (500G): ESP (`/boot`, vfat, ~742M free) +
  ext4 root `/` (~278G free) + swap.
- **TEAM TM8FP6256G** (256G): single NTFS at `/mnt/doc` (data, untouched).
- `/boot/EFI/` contains `systemd/`, `nixos/`, `Linux/`, `BOOT/` — **no
  `Microsoft/` yet** (this is the baseline; verify again after Windows install).

> Note: `efibootmgr` errors with "Unknown command" if not installed — run it via
> `nix-shell -p efibootmgr` as shown, or add `efibootmgr` to `home/packages.nix`.
> You'll need it for Stage 3 (fixing boot order).

### NVRAM boot-entry baseline (confirmed 2026-07-29)

Save this. After Windows installs you'll compare to spot the new entry and
restore NixOS as default.

```
BootCurrent: 0003   ← Linux Boot Manager (systemd-boot), i.e. NixOS
BootOrder:   2002,2003,0003,2001,0001,0002
Boot0001* Internal UEFI Shell
Boot0002* EFI Hard Drive (Phison ESO512GHLCA1-E9C)   ← generic fallback to ESP p1
Boot0003* Linux Boot Manager  → \EFI\systemd\systemd-bootx64.efi   ← NixOS ★
Boot2001* EFI USB Device
Boot2002* EFI DVD/CDROM
Boot2003* EFI Network
```

Key facts:
- **`Boot0003` = NixOS (systemd-boot).** This is the entry to keep first.
- Currently `BootOrder` lists 2002/2003 (CD/Network) before 0003, but since no
  CD/network is present at boot, NixOS boots first in practice. The firmware
  falls through to 0003.
- **No Windows entry yet** — expected. After install Windows will add a new
  `BootXXXX* Windows Boot Manager` and likely rewrite `BootOrder` to put itself
  first. The fix is `-o 0003,<windows-id>` (see Stage 3).

### Make the installer USB (single USB, used twice)

**Phase A — NixOS live USB** (for the shrink): flash it however you originally
did (this machine was installed from a Rufus-made USB). This happens *before*
Ventoy.

**Phase B — Ventoy + Windows ISO** (for the Windows install), done *after* the
shrink, from running NixOS:

```fish
# 1. Identify your USB device (not a partition!) — confirm it's the USB by MODEL
lsblk -o NAME,MODEL,SIZE,TRAN   # look for the USB (TRAN=usb), e.g. /dev/sdX

# 2. Ventoy onto the USB (wipes it — the NixOS installer that was on it is gone)
nix-shell -p ventoy-full
sudo ventoy -i /dev/sdX

# 3. Copy the Windows ISO onto Ventoy's data partition
cp /path/to/Windows.iso /run/media/$USER/Ventoy/
```

> The Windows ISO must already be on the NixOS disk before this step. Download
> it from microsoft.com first (~5G).

The NixOS live USB is whatever you already have.

---

## Stage 1 — Shrink root (offline, from NixOS live USB)

**This step needs the live USB.** ext4 cannot be shrunk online.

1. Boot the **NixOS live USB**.
2. Open a root shell. Do **not** mount `/dev/nvme0n1p2`.

### GUI path (recommended): use GParted

```fish
nix-shell -p gparted
sudo gparted
```

- Select `/dev/nvme0n1`.
- Right-click `nvme0n1p2` → **Resize/Move**.
- Drag the **right edge left** to new size ≈ **400 GiB** (frees ~64G between
  `p2` and `p3`).
- Click **Resize**, then the green checkmark to apply.
- The freed space stays **unallocated** — do not format it. Windows will create
  its own MSR + recovery partitions there.

### CLI path (no GParted): resize2fs + parted

Shrink order for **shrink** is the reverse of grow: **filesystem first, then
partition**.

⚠️ First, confirm which device name the Phison disk got on the live USB:

```fish
lsblk -o NAME,MODEL,SIZE,FSTYPE
# Find the row whose MODEL = "Phison ESO512GHLCA1-E9C" (500G). In the examples
# below it's called /dev/nvme0n1, but on this machine it may equally be nvme1n1.
# Substitute YOUR real device name everywhere below.
```

```fish
# 1. fsck the unmounted filesystem (the NixOS root partition, p2)
sudo e2fsck -f /dev/nvme0n1p2

# 2. Shrink the ext4 filesystem to the target size FIRST
sudo resize2fs /dev/nvme0n1p2 407G

# 3. Note current partition end
sudo parted /dev/nvme0n1 unit s print
#    Record p2's start sector (call it P2_START).
#    Target new end sector = P2_START + (407 GiB in sectors).
#    407 GiB = 407 * 1024 * 1024 * 1024 / 512 = 853529856 sectors

# 4. Resize the partition entry to match (use the computed end)
sudo parted /dev/nvme0n1 resizepart 2 853529856s
# (substitute the real computed end for your P2_START)
```

If you're unsure computing the exact end sector, use the GParted GUI — it does
this arithmetic for you and is much safer.

### Verify before rebooting back to NixOS

```fish
sudo parted /dev/nvme0n1 print free
# Expect: p2 now ~407G, and a block of "Free Space" ~60G between p2 and p3.
```

Reboot to NixOS and confirm it boots normally before touching Windows. If NixOS
won't boot after the shrink, the filesystem/partition end mismatched — boot
live USB again and re-run `e2fsck -f /dev/nvme0n1p2` then `resize2fs` to repair.

---

## Stage 2 — Install Windows

1. Plug in the **Ventoy USB**, reboot, enter the boot menu (F12), boot the
   **Windows ISO** via Ventoy.
2. In setup choose **Custom: Install Windows only (advanced)**.
3. Select the **unallocated space** (~64G) you freed. Windows auto-creates its
   MSR + recovery partition + NTFS inside it.
4. Windows detects the existing 1G ESP and writes its bootloader there as
   `/EFI/Microsoft/Boot/bootmgfw.efi`. **Do not** let Windows reformat the ESP.
5. Complete OOBE, reach the desktop, then reboot.

> If Windows complains the system partition is too small or offers to
> reformat the EFI partition — **cancel**. 1G / 742M free is plenty for both
> bootloaders. This only happens if the ESP is broken or ~100M.

---

## Stage 3 — Restore NixOS as default boot

Windows will almost certainly rewrite `BootOrder` to put its own new entry first.
Your NixOS entry is **`Boot0003` (Linux Boot Manager)** — keep it at the front.

### Path A — lucky: systemd-boot menu still shows

Reboot → systemd-boot menu appears → you see both `NixOS` and
`Windows Boot Manager`. Press `d` on the NixOS entry to make it default. Done.
(`efibootmgr` may still show Windows first in `BootOrder`, but systemd-boot's
own default overrides that for the next boot.)

### Path B — common: boots straight into Windows

**Step 1.** Get back into NixOS one of these ways:
- At the Acer logo, **F12 → boot menu → "Linux Boot Manager"** (one-shot).
- Or **F2 → firmware → Boot** → set **"Linux Boot Manager"** as first entry.

**Step 2.** From NixOS, fix `BootOrder` permanently:

```fish
nix-shell -p efibootmgr -c 'efibootmgr -v'

# Find the new entry Windows added, e.g.:
#   Boot0000* Windows Boot Manager  ...  (Windows usually grabs 0000)
#
# Put NixOS (0003) FIRST, Windows SECOND:
sudo efibootmgr -o 0003,0000
#
# Generic form: list NixOS's 0003, then every other bootable id, comma-separated:
sudo efibootmgr -o 0003,0000,0001,0002
```

> The exact Windows `BootXXXX` number is determined *after* install — Windows
> commonly takes `0000` if free, but not always. Re-read `efibootmgr -v` once
> Windows is installed and use whatever number the new "Windows Boot Manager"
> entry got. The order you pass to `-o` is the boot order; first = default.

**Verify:**
```fish
nix-shell -p efibootmgr -c 'efibootmgr'
# BootCurrent should be 0003, and BootOrder should start with 0003.
```

---

## Stage 4 — Verify dual-boot works (from NixOS)

```fish
# systemd-boot should list Windows Boot Manager
bootctl list

# ESP should now contain both bootloaders
ls /boot/EFI/
# Expect: systemd/  nixos/  Microsoft/  (and maybe Boot/)

# Confirm boot order
efibootmgr
```

If `bootctl list` is missing Windows, Windows didn't write to the shared ESP —
it created its own ESP on the Phison disk. Check with `lsblk` / `parted`; if so,
the NixOS wiki's "EFI with multiple disks" + edk2-uefi-shell section applies. This
is unlikely on this layout but is the fallback.

---

## Stage 5 — Required Windows settings (do once, in Windows)

These prevent the classic dual-boot foot-guns.

### 1. Disable Fast Startup

Otherwise Windows hibernates its filesystems and locks the shared NTFS data
disk (`/mnt/doc`), so NixOS can't mount it safely.

**Control Panel → Power Options → Choose what the power buttons do →** uncheck
**"Turn on fast startup"**. (Click "Change settings that are currently
unavailable" first if the checkbox is greyed out.)

### 2. Fix the clock

Windows assumes RTC is local time; NixOS assumes UTC. Pick **one** approach:

- **Recommended** — tell Windows the RTC is UTC (one-time registry edit, keeps
  NixOS and the flatpak UTC setup correct):

  ```
  reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
  ```

- **Alternative** — tell NixOS the RTC is local time (worse: conflicts with the
  flatpak-UTC note in repo memory):

  ```nix
  time.hardwareClockInLocalTime = true;
  ```

### 3. Sharing files (optional)

`/mnt/doc` (`nvme1n1p1`, NTFS) is shared. With Fast Startup off, NixOS mounts it
read/write safely (already configured via `modules/automount.nix`).

---

## Quick reference: the whole flow

```
running NixOS  ──▶ Stage 0: checks + make Ventoy/NixOS live USBs
                          │
   boot NixOS live USB ───┤
                          ▼
                  Stage 1: shrink nvme0n1p2 (ext4, offline) → ~400G
                          │
                          ▼
   reboot NixOS ──▶ verify it still boots
                          │
   boot Ventoy/Windows ───┤
                          ▼
                  Stage 2: install Windows into freed ~64G (shared ESP)
                          │
                          ▼
   reboot → firmware ──▶ Stage 3: set systemd-boot first (F2 or efibootmgr)
                          │
                          ▼
   NixOS ──▶ Stage 4: bootctl list / ls /boot/EFI → confirm both
                          │
                          ▼
   Windows ──▶ Stage 5: disable Fast Startup, set UTC clock
```

---

## Risk checklist

- ✅ ESP 1G / 742M free — enough for both bootloaders; Windows won't need to
  reformat it.
- ✅ ext4 root with 278G free → shrinking to 400G leaves huge headroom.
- ✅ `/mnt/doc` on `nvme1n1` is a separate disk — untouched by this resize.
- ✅ `modules/bootloader.nix` already has systemd-boot + `canTouchEfiVariables`
  — no NixOS config change for the bootloader.
- ⚠️ ext4 shrink **must be offline** (live USB) — filesystem first, then
  partition.
- ⚠️ Secure Boot is off — leave it off (this NixOS isn't signed).
- ⚠️ Disable Windows Fast Startup or `/mnt/doc` becomes unmountable in NixOS.
