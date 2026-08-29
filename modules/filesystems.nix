{
  # Enable global NTFS support (installs helper programs like ntfs-3g).
  boot.supportedFilesystems = [ "ntfs" ];

  # --- Internal NTFS (NVMe "doc") -------------------------------------------
  # /dev/nvme1n1p1 — always present at boot, declared statically.
  # External/removable drives are NOT declared here: they are auto-mounted
  # by Plasma's udisks2 backend, with dirty-volume cleanup handled by the
  # udev rule in `modules/automount.nix`. See that file for details.
  fileSystems."/mnt/doc" = {
    device = "/dev/disk/by-uuid/7450AFA950AF7092";
    fsType = "ntfs-3g";
    options = [ "rw" "uid=1000" "gid=100" "nofail" ];
  };

  # --- Internal NTFS (NVMe "shared") ----------------------------------------
  # /dev/nvme0n1p7 — 200 GiB carved out of the shrunken ext4 root, shared with
  # Windows: program installs (SolidWorks, CX-One), documents, video.
  #
  # Uses the in-kernel `ntfs3` driver rather than FUSE `ntfs-3g` (as /mnt/doc
  # above does). This volume holds large media on NVMe, where ntfs-3g's
  # single-threaded FUSE overhead is the bottleneck; /mnt/doc and the USB
  # drives handled by `modules/automount.nix` are bus-limited, so they take
  # the slower-but-dirty-tolerant driver instead.
  #
  # PREREQUISITE: Windows Fast Startup and hibernation must stay disabled
  # (`powercfg /h off` from an admin prompt). Otherwise Windows leaves the
  # volume dirty on shutdown and ntfs3 refuses it with:
  #     ntfs3(nvme0n1p7): volume is dirty and "force" flag is not set!
  # `nofail` keeps that from blocking boot; recover with:
  #     sudo ntfsfix -d /dev/nvme0n1p7
  # If dirty volumes become routine, switch fsType to "ntfs-3g".
  fileSystems."/mnt/shared" = {
    device = "/dev/disk/by-uuid/57FE45F00AC89C8B";
    fsType = "ntfs3";
    options = [ "rw" "uid=1000" "gid=100" "umask=0022" "windows_names" "nofail" ];
  };
}
