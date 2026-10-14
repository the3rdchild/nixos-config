{
  # Enable global NTFS support (installs helper programs like ntfs-3g).
  boot.supportedFilesystems = [ "ntfs" ];

  # The 256 GB TEAM TM8FP6256G that used to be /mnt/doc (UUID 7450AFA950AF7092)
  # was removed for good on 2026-10-15 — it hung the firmware at the Acer logo.
  # Its contents are backed up on the "games" disk under backup-team/, and this
  # repo moved from /mnt/doc/config to /mnt/shared/nixos-config.
  #
  # External/removable drives are NOT declared here: they are auto-mounted
  # by Plasma's udisks2 backend, with dirty-volume cleanup handled by the
  # udev rule in `modules/automount.nix`. See that file for details.

  # --- Internal NTFS (NVMe "shared") ----------------------------------------
  # 200 GiB carved out of the shrunken ext4 root (partition 7 of the 512 GB
  # Phison on PCI 02:00.0), shared with Windows: program installs (SolidWorks,
  # CX-One), documents, video, and the working tree of this repo.
  #
  # Identify it by UUID, not by /dev/nvmeXn1: with two NVMe drives fitted the
  # kernel's numbering raced between boots, and it will again if a second
  # drive is ever added.
  #
  # Uses the in-kernel `ntfs3` driver. This volume holds large media and the
  # repo working tree on NVMe, where ntfs-3g's single-threaded FUSE overhead
  # (CPU paid per operation, not per byte) is the bottleneck. The USB drives
  # handled by `modules/automount.nix` still take FUSE `ntfs-3g`: those are
  # bus-limited, and the removable ones benefit from its tolerance of a dirty
  # volume left behind by a machine that was not shut down cleanly.
  #
  # PREREQUISITE: Windows Fast Startup and hibernation must stay disabled
  # (`powercfg /h off` from an admin prompt). Otherwise Windows leaves the
  # volume dirty on shutdown and ntfs3 refuses it with:
  #     ntfs3(...p7): volume is dirty and "force" flag is not set!
  # `nofail` keeps that from blocking boot — but then /mnt/shared, and this
  # repo with it, is simply absent. Recover by UUID:
  #     sudo ntfsfix -d /dev/disk/by-uuid/57FE45F00AC89C8B
  # If dirty volumes become routine, switch fsType to "ntfs-3g".
  fileSystems."/mnt/shared" = {
    device = "/dev/disk/by-uuid/57FE45F00AC89C8B";
    fsType = "ntfs3";
    options = [ "rw" "uid=1000" "gid=100" "umask=0022" "windows_names" "nofail" ];
  };
}
