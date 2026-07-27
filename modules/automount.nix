# Auto-mount + auto-clean for removable NTFS drives.
#
# Problem this solves:
#   When a USB NTFS drive is unplugged without a clean unmount (or was last
#   used on Windows with Fast Startup / hibernation), its volume is marked
#   "dirty". The kernel ntfs3 driver then refuses to mount it with:
#       ntfs3(sda2): volume is dirty and "force" flag is not set!
#   and even ntfs-3g can be sluggish on a dirty volume. The historical fix
#   was running `sudo ntfsfix /dev/sdXN` by hand for *each* offending drive.
#
# What this module does:
#   1. Explicitly enables udisks2 (Plasma6's auto-mount backend).
#   2. Installs a udev rule that runs `ntfsfix -d` (clears the dirty bit
#      only — non-destructive) on every NTFS partition the moment it is
#      plugged in, *before* udisks2 tries to mount it.
#   3. Sets udisks2 mount options to prefer ntfs-3g (tolerant of dirty
#      volumes) for external NTFS, with sane ownership for the desktop user.
#
# Net effect: any new NTFS drive (or the same one after a bad unplug) can
# just be plugged in and opened from Dolphin, no manual ntfsfix, no per-UUID
# entry in filesystems.nix.
{ config, pkgs, lib, ... }:
let
  primaryUser = "noouoops";       # uid 1000, gid 100 (users)

  # Standalone helper wrapped in a Nix-store script so udev can invoke it
  # with a single argument ($env{DEVNAME}) and we get clean, observable
  # logging via systemd-journald (tag: `ntfsfix-udev`).
  ntfsfix-udev = pkgs.writeShellScriptBin "ntfsfix-udev" ''
    dev="$1"
    ${pkgs.util-linux}/bin/logger -t ntfsfix-udev "running ntfsfix -d on $dev"
    ${pkgs.ntfs3g}/bin/ntfsfix -d "$dev" 2>&1 | ${pkgs.util-linux}/bin/logger -t ntfsfix-udev
  '';
in
{
  # --- 1. Auto-mount backend (also pulled in by Plasma6, made explicit) -----
  services.udisks2.enable = true;

  # --- 2. udev: clear NTFS dirty flag on plug-in ----------------------------
  # `ntfsfix -d` only clears the dirty bit and replays the journal; it is
  # safe to run on a healthy volume. Restricted to USB-attached volumes so
  # internal NTFS volumes (e.g. the NVMe "doc") are left untouched.
  #
  # NOTE on filters:
  #   * ENV{ID_BUS}=="usb" is unreliable on PARTITIONS — it is usually only
  #     set on the parent disk (sda), not on sda2. ENV{ID_PATH} is set on
  #     both and contains a "-usb-" segment for USB-attached devices, so it
  #     is the correct discriminator here.
  #   * The script logs to the journal under tag `ntfsfix-udev`; verify with
  #         journalctl -t ntfsfix-udev      (NOTE: NO -k flag; this is userspace)
  services.udev.extraRules = ''
    ACTION=="add", \
      SUBSYSTEM=="block", \
      ENV{ID_FS_TYPE}=="ntfs|ntfs-3g", \
      ENV{ID_FS_USAGE}=="filesystem", \
      ENV{ID_PATH}=="*-usb-*", \
      RUN+="${ntfsfix-udev}/bin/ntfsfix-udev $env{DEVNAME}"
  '';

  # --- 3. udisks2: prefer ntfs-3g + sane mount options ----------------------
  # ntfs-3g (FUSE) is slower than the kernel ntfs3 driver, but it tolerates
  # dirty/hibernated volumes far better — the right trade-off for external
  # drives over USB where the bus, not the driver, is the bottleneck.
  #
  # IMPORTANT: only options accepted by the mount(2) syscall go here.
  # fstab-only options like `auto`/`noauto`/`user`/`nouser` are REJECTED by
  # udisks2 with "Mount option `X' is not allowed".
  environment.etc."udisks2/mount_options.conf".text = ''
    [defaults]
    # Common defaults applied to NTFS volumes mounted by udisks2.
    ntfs_defaults=uid=1000,gid=100,dmask=027,fmask=137,windows_names,exec
    # Force the FUSE ntfs-3g driver instead of the in-kernel ntfs3.
    ntfs_force_driver=ntfs-3g
  '';

  # Make ntfs-3g helper discoverable for any ad-hoc manual mounts.
  environment.systemPackages = with pkgs; [ ntfs3g ];
}

