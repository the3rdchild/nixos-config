{
  # Enable global NTFS support (installs helper programs like ntfs-3g)
  boot.supportedFilesystems = [ "ntfs" ];

  # Define your specific drive mount
  fileSystems."/mnt/doc" = {
    device = "/dev/disk/by-uuid/7450AFA950AF7092";
    fsType = "ntfs-3g";
    options = [ "rw" "uid=1000" "gid=100" "nofail" ];
  };
}
