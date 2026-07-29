# NixOS + Windows dual-boot

Adding Windows alongside NixOS on the **Phison 500G NVMe** — the disk that holds
NixOS root `/`, the ESP, and swap. NixOS stays the default boot; Windows is
installed into ~68G freed by shrinking the existing ext4 root.

This guide is specific to this machine — see the **Target layout** section for
why most of the generic NixOS-wiki complexity does not apply here.

> ## ✅ Completed 2026-07-30
>
> This was carried out successfully. See **Outcome** at the bottom for the final
> verified layout and boot entries.
>
> **One thing went wrong and is not covered below:** the Windows installer
> corrupted the **primary GPT table**, leaving NixOS in emergency mode with
> `Timed out waiting for device /dev/disk/by-uuid/...`. Data was intact; the
> fix was rebuilding the GPT primary from its backup. Full write-up:
> **[nixos-gpt-recovery.md](./nixos-gpt-recovery.md)** — read it *before*
> attempting this on another machine.

> ## ⚠️ CRITICAL — NVMe names are NOT stable on this machine
>
> On this Acer the kernel assigns `nvme0n1` / `nvme1n1` by enumeration order,
> which **changes between boots**. Over the course of this operation the names
> swapped **three times** — the Phison was `nvme1n1` before the shrink and
> `nvme0n1` after the GPT recovery.
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

# 2. Unmount it first — `ventoy -i` refuses to touch a mounted device
udisksctl unmount -b /dev/sdX1

# 3. Ventoy onto the USB (wipes it — the NixOS installer that was on it is gone)
#    ventoy is BOTH unfree AND flagged insecure in nixpkgs, so BOTH vars are needed
set -x NIXPKGS_ALLOW_UNFREE 1
set -x NIXPKGS_ALLOW_INSECURE 1
nix-shell -p ventoy-full
sudo ventoy -i /dev/sdX

# 4. Copy the Windows ISO onto Ventoy's data partition (exFAT, so >4G is fine)
cp /mnt/doc/win11.ISO /run/media/$USER/Ventoy/
sync                            # cp returns LONG before 5.5G is on the stick
udisksctl unmount -b /dev/sdX1
```

> **Two separate nixpkgs gates.** `allowUnfree` (already `true` in
> `modules/setting.nix`) is *not* enough — ventoy is additionally marked
> **insecure** ([nixpkgs#404663](https://github.com/NixOS/nixpkgs/issues/404663):
> unauditable binary blobs). Note `nix-shell` reads
> `~/.config/nixpkgs/config.nix`, **not** the NixOS system config, so the system's
> `allowUnfree` does not apply to it at all.
>
> Adding `ventoy-full` to `environment.systemPackages` needs
> `nixpkgs.config.permittedInsecurePackages = [ "ventoy-1.1.12" ];` — which pins
> the version string and breaks rebuilds on every nixpkgs bump. **Don't.** Use the
> throwaway shell above, or skip Ventoy entirely (below).

### Alternative: plain `dd`, no Ventoy

For a single ISO this is simpler and avoids the unfree/insecure package
altogether. Windows 11 ISOs are UDF with `/EFI/BOOT/BOOTX64.EFI`, so UEFI boots
them directly — this is what Rufus produced for the original install USB.

```fish
udisksctl unmount -b /dev/sdX1
sudo dd if=/mnt/doc/win11.ISO of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

⚠️ Triple-check `of=` — writing to the Phison would destroy the NixOS you just
resized. Ventoy's only advantage is a reusable multi-ISO stick; that *did* turn
out useful here, since the GPT recovery needed a NixOS ISO added alongside the
Windows one without reflashing.

### MBR vs GPT for the Ventoy stick

`ventoy -i` defaults to **MBR**; `-g` forces GPT. **MBR is fine** — Ventoy's MBR
layout boots both Legacy BIOS and UEFI, because the `VTOYEFI` partition is a FAT
ESP and UEFI firmware happily boots a FAT ESP on an MBR disk. Not worth redoing
if you forgot `-g`.

Resulting layout:

| Part | Size | FS | Label | Role |
|---|---|---|---|---|
| sdX1 | rest | exfat | Ventoy | ISOs go here |
| sdX2 | 32 M | vfat | VTOYEFI | bootloader |

> `ventoy -v` is not a version flag — Ventoy treats every argument as a device.
> Use `ventoy -l /dev/sdX` to inspect an existing install.

> The Windows ISO must already be on the NixOS disk before this step. Download
> it from microsoft.com first (~5G).

The NixOS live USB is whatever you already have.

---

## Stage 1 — Shrink root (offline, from NixOS live USB)

**This step needs the live USB.** ext4 cannot be shrunk online.

1. Boot the **NixOS live USB**.
2. Open a root shell. Do **not** mount the NixOS root partition (`p2`).

### GUI path (recommended): use GParted

```fish
nix-shell -p gparted
sudo gparted
```

- Select the disk whose **MODEL is `Phison ESO512GHLCA1-E9C`** — confirm in the
  top-right dropdown, not by `nvmeXn1` name.
- Right-click the ext4 root partition (`p2`) → **Resize/Move**.
- Drag the **right edge left** to new size ≈ **400 GiB** (frees ~68G between
  `p2` and `p3`).
- Click **Resize**, then **the green ✓ checkmark to actually apply**, and wait
  for the "All operations successfully completed" dialog. Queuing the resize
  without applying looks identical in the GUI — this is exactly what went wrong
  on the first attempt here.
- The freed space stays **unallocated** — do not format it. Windows will create
  its own MSR + recovery partitions there.

### CLI path (no GParted): resize2fs + parted

Shrink order for **shrink** is the reverse of grow: **filesystem first, then
partition**.

⚠️ First, resolve the Phison disk **by model**, never by name. This sets `$DISK`
so nothing below hardcodes `nvme0n1`/`nvme1n1`:

```fish
set DISK /dev/(lsblk -dno NAME,MODEL | string match -r '^(\w+)\s+Phison' | tail -1)
echo $DISK                        # sanity-check before continuing
lsblk -o NAME,MODEL,SIZE,FSTYPE $DISK
```

If that returns nothing or the wrong disk, fall back to reading
`lsblk -o NAME,MODEL,SIZE` by eye and setting `set DISK /dev/nvmeXn1` manually.

```fish
# 1. fsck the unmounted filesystem (the NixOS root partition, p2)
sudo e2fsck -f {$DISK}p2

# 2. Shrink the ext4 filesystem to the target size FIRST
sudo resize2fs {$DISK}p2 400G

# 3. Note current partition end
sudo parted $DISK unit s print
#    Record p2's start sector (call it P2_START).
#    Target new end sector = P2_START + (400 GiB in sectors) - 1.
#    400 GiB = 400 * 1024 * 1024 * 1024 / 512 = 838860800 sectors

# 4. Resize the partition entry to match (use the computed end)
sudo parted $DISK resizepart 2 838399999s
# (this machine's actual value — recompute for your own P2_START)
```

If you're unsure computing the exact end sector, use the GParted GUI — it does
this arithmetic for you and is much safer.

### Verify before rebooting back to NixOS — HARD GATE

**Do not proceed to Phase B until this shows the gap.** On the first attempt the
GParted resize was queued but never applied (the green ✓ was not clicked), and
that was only caught later — after the live USB had almost been reflashed as
Ventoy, which would have made redoing the shrink impossible without
re-downloading the NixOS image.

```fish
sudo parted $DISK unit s print free
# REQUIRED: a "Free Space" row of ~68G BETWEEN partitions 2 and 3.
# If that row is absent, the resize did NOT apply. Do not continue.
```

Cross-check that the filesystem and partition agree — they must be byte-identical:

```fish
sudo dumpe2fs -h {$DISK}p2 | grep -E 'Block count|Block size'
# Block count x Block size must equal p2's sector count x 512.
```

This machine, after a successful shrink:

| Check | Value |
|---|---|
| p2 sectors | 836,298,752 × 512 = 428,184,961,024 B |
| ext4 blocks | 104,537,344 × 4096 = 428,184,961,024 B |
| Free gap | sectors 838,400,000 → 981,760,199 = **68.36 GiB** |

A `df -h /` still reporting the *old* size is the tell-tale that nothing
happened — 400 GiB shows as ~393 G, not 459 G.

Reboot to NixOS and confirm it boots normally before touching Windows. If NixOS
won't boot after the shrink, the filesystem/partition end mismatched — boot
live USB again and re-run `e2fsck -f {$DISK}p2` then `resize2fs` to repair.

> If instead it drops to **emergency mode** with `Timed out waiting for device
> /dev/disk/by-uuid/...`, that is a *different* failure — most likely a corrupt
> GPT, not a bad resize. See
> [nixos-gpt-recovery.md](./nixos-gpt-recovery.md).

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
sudo efibootmgr -v
```

**What this machine actually showed after the Windows install:**

```
BootCurrent: 0003
BootOrder: 0004,2002,2003,0003,2001,0001      ← Windows (0004) hijacked the front
Boot0003* Linux Boot Manager    HD(1,GPT,9f5f4e04-…-889f585cece3,0x1000,0x200000)/\EFI\systemd\systemd-bootx64.efi
Boot0004* Windows Boot Manager  HD(1,GPT,9f5f4e04-…-889f585cece3,0x1000,0x200000)/\EFI\Microsoft\Boot\bootmgfw.efi
```

Note the **partition GUID is identical** on both (`9f5f4e04-…`, offset `0x1000`,
length `0x200000` = 1 G) — proof Windows wrote to the *shared* ESP rather than
creating its own. That is the good case.

Fix — put NixOS first, keep the rest of the order intact:

```fish
sudo efibootmgr -o 0003,0004,2002,2003,2001,0001
```

> ⚠️ **Windows did NOT take `0000` here — it took `0004`.** The number is only
> known after install. Always re-read `efibootmgr -v` and use the real id; never
> copy the number from this doc.
>
> `Boot0000* EFI USB Device (VendorCoProductCode)` with `HD(2,MBR,…)` is just the
> leftover Ventoy stick. Harmless, not in `BootOrder`.

**Verify:**
```fish
sudo efibootmgr | head -3          # BootOrder must start with 0003
sudo bootctl list | grep -i title  # must include "Windows Boot Manager"
```

`/boot` is vfat mounted root-only, so `ls /boot/EFI` and `bootctl list` both
need `sudo` — without it they fail with `Permission denied`, which is not a
symptom of anything being broken.

### Trim the boot menu

After the install, `Windows Boot Manager` lands at the **bottom** of the
systemd-boot menu — below every NixOS generation. This machine had **66** of
them, making Windows unreachable without a long scroll. Fixed in
`modules/bootloader.nix`:

```nix
boot.loader = {
  systemd-boot.enable = true;
  systemd-boot.configurationLimit = 10;
  efi.canTouchEfiVariables = true;
};
```

Only limits what is *displayed*; old generations stay in
`/nix/var/nix/profiles` and remain rollback-able from the CLI.

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

`/mnt/doc` (the TEAM 256G disk, NTFS) is shared. With Fast Startup off, NixOS mounts it
read/write safely (already configured via `modules/automount.nix`).

---

## Quick reference: the whole flow

```
running NixOS  ──▶ Stage 0: checks + make Ventoy/NixOS live USBs
                          │
   boot NixOS live USB ───┤
                          ▼
                  Stage 1: shrink Phison p2 (ext4, offline) → ~400G
                           ↳ VERIFY the free-space gap before continuing
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
- ✅ `/mnt/doc` is on the TEAM 256G disk — a separate physical disk, untouched
  by this resize.
- ✅ `modules/bootloader.nix` already has systemd-boot + `canTouchEfiVariables`
  — no NixOS config change for the bootloader.
- ⚠️ ext4 shrink **must be offline** (live USB) — filesystem first, then
  partition.
- ⚠️ Secure Boot is off — leave it off (this NixOS isn't signed).
- ⚠️ Disable Windows Fast Startup or `/mnt/doc` becomes unmountable in NixOS.
- ⚠️ **The Windows installer can corrupt the primary GPT.** It did here. Back up
  the GPT *before* installing, and keep `gptfdisk` installed — see
  [nixos-gpt-recovery.md](./nixos-gpt-recovery.md).

---

## Outcome (verified 2026-07-30)

### Final partition layout — Phison ESO512GHLCA1-E9C

| Part | Size | Content |
|---|---|---|
| p1 | 1 G | ESP, `/boot` — **shared**, not reformatted |
| p2 | 398.8 G | NixOS root (ext4, label `root`) |
| p3 | 16 M | Microsoft Reserved (MSR) |
| p4 | 67.5 G | Windows C: (NTFS) |
| p5 | 849 M | Windows recovery (NTFS) |
| p6 | 8.8 G | swap |

p3–p5 fit exactly inside the 68.36 GiB gap freed by the shrink. The TEAM 256G
data disk (`/mnt/doc`) was untouched throughout.

`/boot/EFI/` now contains: `BOOT Linux Microsoft nixos systemd` — the
`Microsoft/` directory confirms the shared-ESP outcome, so none of the
XBOOTLDR / edk2-uefi-shell fallbacks were needed.

### Everything that had to be done

| Item | Where |
|---|---|
| Shrink root 467 G → 398.8 G | GParted, live USB |
| Install Windows into the gap | Windows installer |
| **Repair corrupted primary GPT** | [nixos-gpt-recovery.md](./nixos-gpt-recovery.md) |
| `BootOrder` → NixOS first | `efibootmgr -o 0003,0004,…` |
| Cap boot menu at 10 entries | `modules/bootloader.nix` |
| Install recovery tooling permanently | `modules/package.nix` |
| Back up the GPT | `sgdisk --backup=` → `/mnt/doc` |
| Disable Fast Startup + set UTC clock | inside Windows |

### Recovery tooling now installed permanently

Added to `modules/package.nix`, because if the GPT breaks again you may not be
able to boot far enough to run `nix-shell`:

```nix
efibootmgr
parted
gparted
gptfdisk    # sgdisk, gdisk, cgdisk, fixparts
```

### ⚠️ `/etc/nixos` is NOT this repo

Discovered mid-operation: `/etc/nixos` is a **real directory**, not a symlink to
`/mnt/doc/config`. The system is built from `/etc/nixos`; this git repo is a
separate, diverged copy. Editing the repo does **not** affect
`nixos-rebuild --flake /etc/nixos#noouoops`.

Verify before editing any config:

```fish
readlink -f /etc/nixos
diff -rq /etc/nixos /mnt/doc/config | grep -v '^Files .*/result/'
```

Until the two are unified, config changes intended to take effect must go into
`/etc/nixos`.
