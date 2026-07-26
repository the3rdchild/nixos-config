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
