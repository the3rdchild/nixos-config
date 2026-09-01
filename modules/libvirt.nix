{ pkgs, lib, ... }:
let
  # ── The Windows virtio driver ISO, built here rather than downloaded.
  #
  # nixpkgs' `virtio-win` is NOT the ISO Red Hat ships — it is that ISO's
  # *extracted contents*, laid out at the package root (amd64/, NetKVM/,
  # viostor/, virtio-win-guest-tools.exe, ...). Two consequences, both of which
  # bite quietly:
  #
  #   1. Putting `virtio-win` in environment.systemPackages does nothing
  #      useful. NixOS' system-path only links the conventional top-level dirs
  #      (bin, share, lib, ...) out of a package, and none of this package's
  #      content is under those — so nothing at all lands in
  #      /run/current-system/sw. It is not that the ISO is somewhere else; it
  #      is that there is no ISO and no linked tree either.
  #   2. Windows Setup needs a block device to load a storage driver from. A
  #      directory in the Nix store cannot be attached as a CD-ROM.
  #
  # So the tree gets packed back into an ISO. This is the one piece of install
  # media that *can* be declarative — the Windows and CX-One images are
  # unredistributable blobs and live in /mnt/shared/VM/iso instead.
  virtio-win-iso = pkgs.runCommand "virtio-win.iso"
    { nativeBuildInputs = [ pkgs.xorriso ]; }
    ''
      xorriso -as mkisofs -V VIRTIO-WIN -J -joliet-long -r \
        -o "$out" ${pkgs.virtio-win}
    '';
in
{
  # ── libvirt/KVM, for the one thing that genuinely needs Windows.
  #
  # Omron CX-One (CX-Programmer, CX-Designer, CX-Integrator, ...) is Windows
  # only — no Linux build, no port, and no vendor support for Wine. The media
  # here is the V4.60 DVD tree on the "Programs" USB disk:
  #     /run/media/noouoops/Programs/Programs/DVD_CxOne_V4.60/CxOne_V4.60
  # an InstallShield setup.exe + CX-One_V4.msi, with the licence key beside it
  # in Key_Install.txt. It installs cleanly in a Windows guest; under Wine the
  # installer, the .NET prerequisites and the activation step each fail in
  # their own way, and USB drivers are a hard no there regardless — which is
  # disqualifying, because the PLC link here is USB-serial (see below).
  #
  # This replaces the dual boot for PLC work, so the machine no longer has to
  # leave Hyprland to talk to a controller.

  virtualisation.libvirtd = {
    enable = true;

    # No guest starts by itself. This box has 15 GiB of RAM and already runs
    # under memory pressure (../modules/memory.nix documents the swap thrash
    # that zram was added to fix) — a 4-6 GiB guest coming up at boot would
    # undo that work. Start it by hand from virt-manager when it is wanted.
    onBoot = "ignore";
    onShutdown = "shutdown";

    qemu = {
      package = pkgs.qemu_kvm;

      # Windows 11 refuses to install without a TPM 2.0. swtpm emulates one
      # per guest, which is what lets the official Microsoft ISO past its
      # hardware check without registry hacks.
      swtpm.enable = true;

      # NOTE: there is deliberately no `ovmf` block here. That submodule was
      # removed from nixpkgs — every OVMF image QEMU ships, Secure Boot builds
      # included, is now registered with libvirt by default:
      #     "The 'virtualisation.libvirtd.qemu.ovmf' submodule has been
      #      removed. All OVMF images distributed with QEMU are now available
      #      by default."
      # Setting it is a hard eval failure, not a warning. Pick the firmware in
      # virt-manager instead: Customize before install -> Overview -> Firmware
      # -> "UEFI x86_64: ...OVMF_CODE.secboot.fd", which together with the
      # emulated TPM above satisfies the Windows 11 hardware check.
    };
  };

  # NOTE: unlike ./docker.nix, libvirtd's socket activation is deliberately
  # left alone. Docker is masked there because its daemon holds containers and
  # networks resident; libvirtd socket-activates, costs nothing until the first
  # `virsh`/virt-manager connection, and `onBoot = "ignore"` above is already
  # the part that keeps guests from running. Masking the socket too would only
  # mean virt-manager fails to connect until libvirtd is started by hand.

  # ── The PLC cable.
  #
  # The link to the controller is USB-serial (an Omron CS1W-CIF31-class cable,
  # or a CP1's native USB-B port), and the driver that has to claim it is the
  # Omron/FTDI *Windows* driver inside the guest. So the raw USB device is
  # handed to the guest, not a host /dev/ttyUSB* forwarded as a serial port —
  # the latter looks tempting and does not work, because the guest driver
  # expects to see the USB device itself.
  #
  # This option installs the setuid spice-client-glib USB acl helper, which is
  # what lets virt-manager's "Redirect USB device" menu grab the cable at run
  # time, without the guest having to be defined against a fixed bus/port. That
  # matters for a cable that gets plugged and unplugged constantly.
  #
  # No IOMMU work is needed for any of this: USB redirection and libvirt's
  # <hostdev> USB passthrough both operate at the usbfs level, not through
  # VFIO. There is deliberately no intel_iommu=on in ./bootloader.nix, and
  # nothing here wants one — that is only required for *PCI* passthrough,
  # which this machine does not do.
  virtualisation.spiceUSBRedirection.enable = true;

  programs.virt-manager.enable = true;

  users.users.noouoops.extraGroups = [ "libvirtd" ];

  environment.systemPackages = with pkgs; [
    virt-viewer
    usbutils   # lsusb, to identify the PLC cable's vendor:product before passing it
    xorriso    # builds the CX-One install ISO from the DVD tree — see below

  ];

  # Stable path for the ISO built above. /etc entry rather than a bare store
  # path so the create script and virt-manager have something that does not
  # change on every nixpkgs bump; it is a symlink into the store, so it costs
  # nothing beyond the ISO itself.
  environment.etc."virtio-win.iso".source = virtio-win-iso;

  # ── Where guest disks live.
  #
  # /var/lib/libvirt/images, i.e. the ext4 root — NOT /mnt/shared, even though
  # that volume has more free space and is the natural "shared with Windows"
  # home for this sort of thing. Three reasons, all from ./filesystems.nix:
  #
  #   1. It is ntfs3. A qcow2 image on it gets no reliable sparse-file or
  #      fsync semantics, which is exactly what a guest filesystem's write
  #      barriers depend on — an unclean host shutdown can corrupt the guest.
  #   2. It is mounted `nofail`. If Windows ever leaves the volume dirty (the
  #      Fast Startup prerequisite documented there), the mount is simply
  #      absent at boot — and the VM's disk with it.
  #   3. ntfs3 has no notion of the ownership/permissions libvirt's qemu user
  #      needs; the whole volume is uid=1000 gid=100 umask=0022 by mount
  #      option, so per-image ACLs cannot be set at all.
  #
  # Root has ~106 GB free as of 2026-09-01 (198 GB ext4, 80 GB used) and the
  # store is back to 33 GB since the GC in ./setting.nix was fixed, so there
  # is no need to reclaim anything to make room for an 80 GB sparse image.
  #
  # The directory itself has to be created here: neither the libvirtd module
  # nor the daemon makes it, and libvirt has no default storage pool on NixOS,
  # so virt-install fails at the first --disk with
  #     Could not start storage pool: cannot open directory
  #     '/var/lib/libvirt/images': No such file or directory
  # 0711 root:root matches libvirt's own default for this pool — the qemu user
  # needs to traverse in, but not to list, and libvirt chowns each image to it
  # as a guest starts (dynamic ownership).
  systemd.tmpfiles.rules = [
    "d /var/lib/libvirt 0755 root root -"
    "d /var/lib/libvirt/images 0711 root root -"
  ];
}
