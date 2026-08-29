{
  # Enable global NTFS support (installs helper programs like ntfs-3g).
  boot.supportedFilesystems = [ "ntfs" ];

  # --- Internal NTFS (NVMe "doc") -------------------------------------------
  # Internal, always present at boot, declared statically by UUID.
  #
  # CAUTION: do not identify this disk by its /dev/nvmeXn1 name. The two NVMe
  # controllers finish probing in a race, so the kernel's numbering swaps
  # between boots — this volume has been seen as both nvme1n1p1 and nvme0n1p1
  # on consecutive boots of the same system. The stable handles are the UUID
  # below and the PCI address: "doc" is the 256 GB TEAM drive on 03:00.0,
  # root/boot/shared live on the 512 GB Phison on 02:00.0.
  #
  # External/removable drives are NOT declared here: they are auto-mounted
  # by Plasma's udisks2 backend, with dirty-volume cleanup handled by the
  # udev rule in `modules/automount.nix`. See that file for details.
  #
  # Uses the in-kernel `ntfs3` driver, matching /mnt/shared below.
  #
  # This used to be FUSE `ntfs-3g`, on the reasoning quoted below that /mnt/doc
  # is "bus-limited" and so would not notice the slower driver. That reasoning
  # does not hold: this is an internal NVMe (Realtek RTS5765DL controller), not
  # a USB disk, so the bus is nowhere near the limiting factor — the FUSE trip
  # was. Every read and write on this volume was crossing into a userspace
  # daemon and back, which costs CPU per operation rather than per byte, and
  # this is the volume that holds the working tree and everyday documents.
  # On battery that overhead is paid continuously for no benefit.
  #
  # PREREQUISITE, same as /mnt/shared: Windows Fast Startup and hibernation
  # must stay off (`powercfg /h off`), or Windows leaves the volume dirty and
  # ntfs3 refuses to mount it:
  #     ntfs3(nvme0n1p1): volume is dirty and "force" flag is not set!
  # (the nvmeXn1 name in that message is whatever this boot assigned — see the
  # numbering caution above; do not copy it into a repair command.)
  # `nofail` keeps that from blocking boot — but note the consequence is that
  # /mnt/doc is simply absent rather than the system failing loudly. Recover
  # by UUID, which cannot point at the wrong disk:
  #     sudo ntfsfix -d /dev/disk/by-uuid/7450AFA950AF7092
  # To revert, set fsType back to "ntfs-3g" and drop the umask/windows_names
  # options (ntfs-3g takes uid/gid but not these).
  fileSystems."/mnt/doc" = {
    device = "/dev/disk/by-uuid/7450AFA950AF7092";
    fsType = "ntfs3";
    options = [ "rw" "uid=1000" "gid=100" "umask=0022" "windows_names" "nofail" ];
  };

  # --- Internal NTFS (NVMe "shared") ----------------------------------------
  # 200 GiB carved out of the shrunken ext4 root (partition 7 of the 512 GB
  # Phison on PCI 02:00.0 — again, not a stable nvmeXn1 name), shared with
  # Windows: program installs (SolidWorks, CX-One), documents, video.
  #
  # Uses the in-kernel `ntfs3` driver, as /mnt/doc above now does too. This
  # volume holds large media on NVMe, where ntfs-3g's single-threaded FUSE
  # overhead is the bottleneck. The USB drives handled by
  # `modules/automount.nix` still take FUSE `ntfs-3g`: those genuinely are
  # bus-limited, and the removable ones benefit from its tolerance of a dirty
  # volume left behind by a machine that was not shut down cleanly.
  #
  # PREREQUISITE: Windows Fast Startup and hibernation must stay disabled
  # (`powercfg /h off` from an admin prompt). Otherwise Windows leaves the
  # volume dirty on shutdown and ntfs3 refuses it with:
  #     ntfs3(...p7): volume is dirty and "force" flag is not set!
  # `nofail` keeps that from blocking boot; recover by UUID:
  #     sudo ntfsfix -d /dev/disk/by-uuid/57FE45F00AC89C8B
  # If dirty volumes become routine, switch fsType to "ntfs-3g".
  fileSystems."/mnt/shared" = {
    device = "/dev/disk/by-uuid/57FE45F00AC89C8B";
    fsType = "ntfs3";
    options = [ "rw" "uid=1000" "gid=100" "umask=0022" "windows_names" "nofail" ];
  };
}
