{ config, pkgs, ... }:
{
  # ── Hybrid graphics: Intel UHD (Alder Lake-P, PCI:0:2:0)
  #                  + NVIDIA RTX 3050 6GB Laptop / GA107 (PCI:1:0:0)

  hardware.graphics = {
    enable = true;
    enable32Bit = true; # Steam / Proton / Wine
    extraPackages = with pkgs; [
      intel-media-driver # iHD — Gen12 QuickSync decode/encode
      vpl-gpu-rt         # oneVPL runtime
      libvdpau-va-gl     # VDPAU shim over VAAPI
    ];
    extraPackages32 = with pkgs.pkgsi686Linux; [
      intel-media-driver
    ];
  };

  # Gen12 wants iHD, not the legacy i965 driver
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  # Replaces the nouveau fallback and blacklists it automatically
  services.xserver.videoDrivers = [ "nvidia" ];

  # ── Load both GPU stacks in initrd, sequentially, before udev exists.
  #
  # Symptom this fixes: an intermittent unbootable system. On 2026-08-11 boot
  # e3bfe9d3, stage-2 systemd-modules-load inserted nvidia, nvidia_modeset and
  # nvidia_uvm, then blocked on nvidia_drm until systemd killed it at the
  # 90s TimeoutStartSec default:
  #
  #   systemd-modules-load.service: start operation timed out. Terminating.
  #   Consumed 4.691s CPU time over 1min 30.054s wall clock time
  #
  # 4.7s of CPU across 90s of wall clock means it was blocked on a lock, not
  # spinning — and the journal shows what held it: i915 was probing at the same
  # instant from a udev worker (WARNING at intel_bios.c:2793, "(udev-worker)/439"),
  # with the backtrace's "Modules linked in" listing both nvidia(O+) and i915(+)
  # mid-load. Two drivers racing for the same DRM/vgaarb state.
  #
  # Boot then *continued* with no nvidia_drm, which is why it looked so strange:
  # sddm started normally, but the console had already gone to "colour dummy
  # device 80x25" with vgaarb deactivating the vga console, so the result was a
  # black screen with a cursor that looks like a TTY and accepts nothing.
  #
  # This was never a regression — the generation that failed and the one before
  # it have byte-identical kernel, initrd and kernel-params; they differ only in
  # /etc and system-path. It is a race, so rolling back does not help. Every
  # generation is exposed until the ordering is forced.
  #
  # initrd loads these in list order, serially, before udev starts probing in
  # parallel, which closes the window. i915 first so the display is claimed and
  # settled before nvidia touches DRM. The dGPU does power on early as a result,
  # but runtime PM still suspends it afterwards, so finegrained below keeps
  # working — this costs boot-time watts, not battery life.
  boot.initrd.kernelModules = [
    "i915"
    "nvidia"
    "nvidia_modeset"
    "nvidia_uvm"
    "nvidia_drm"
  ];

  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    modesetting.enable = true; # required for Wayland / KWin
    nvidiaSettings = true;

    # Open kernel modules — recommended on Turing and newer (GA107 qualifies)
    open = true;

    # Lets the dGPU fully power down when no offloaded client is running
    powerManagement.enable = true;
    powerManagement.finegrained = true;

    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true; # provides the `nvidia-offload` wrapper
      };
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  environment.systemPackages = with pkgs; [
    # Diagnostics
    libva-utils    # vainfo
    vulkan-tools   # vulkaninfo
    mesa-demos     # glxinfo / eglinfo
    # .nvidia, not .full — .full pulls the entire CUDA stack (~3 GB of
    # libcublas) for AMD/other backends this machine has no use for.
    nvtopPackages.nvidia
  ];
}
