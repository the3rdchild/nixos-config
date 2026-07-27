{
  # Enable global NTFS support (installs helper programs like ntfs-3g).
  boot.supportedFilesystems = [ "ntfs" ];

  # --- Internal NTFS (NVMe "doc") -------------------------------------------
  # /dev/nvme0n1p1 — always present at boot, declared statically.
  # External/removable drives are NOT declared here: they are auto-mounted
  # by Plasma's udisks2 backend, with dirty-volume cleanup handled by the
  # udev rule in `modules/automount.nix`. See that file for details.
  fileSystems."/mnt/doc" = {
    device = "/dev/disk/by-uuid/7450AFA950AF7092";
    fsType = "ntfs-3g";
    options = [ "rw" "uid=1000" "gid=100" "nofail" ];
  };
}
