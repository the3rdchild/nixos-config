{ config, pkgs, ... }:
let
  # Microsoft Edge on the NVIDIA dGPU, as an opt-in second launcher. The normal
  # Edge is untouched, so the two can be compared side by side.
  #
  # Measured with headless Edge 150 on this laptop (WebGL renderer string):
  #   no flags                      SwiftShader (software; headless uses no GPU)
  #   --use-gl=angle --use-angle=gl Intel (Mesa ADL GT2)
  #   ... plus the offload variables  NVIDIA GeForce RTX 3050   (5 of 5 runs)
  #   --use-angle=vulkan            WebGL does not start at all
  # so the variables alone do nothing and the flags alone pick Intel: it takes
  # both. WebGPU had no adapter in any variant. This is the headless GL path;
  # the Wayland window path of a normal, visible Edge was not tested.
  #
  # Chromium forwards a second launch to the Edge that is already running, and
  # that process keeps its own GPU choice, so by default this uses a profile of
  # its own (log in again; settings and extensions are separate) and always
  # starts its own process. `edge-nvidia --main-profile` uses the normal profile
  # instead and refuses while any Edge is running, rather than silently
  # opening a window on the wrong GPU.
  edgeNvidia = pkgs.writeShellScriptBin "edge-nvidia" ''
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __VK_LAYER_NV_optimus=NVIDIA_only

    if [ "''${1:-}" = "--main-profile" ]; then
      shift
      if ${pkgs.procps}/bin/pgrep -u "$(id -u)" -x msedge > /dev/null; then
        echo "edge-nvidia: Edge is already running; a new window would join that process and use its GPU. Close Edge first." >&2
        exit 1
      fi
    else
      set -- --user-data-dir="''${XDG_CONFIG_HOME:-$HOME/.config}/microsoft-edge-nvidia" "$@"
    fi
    exec ${pkgs.microsoft-edge}/bin/microsoft-edge --use-gl=angle --use-angle=gl "$@"
  '';

  edgeNvidiaDesktop = pkgs.makeDesktopItem {
    name = "edge-nvidia";
    desktopName = "Microsoft Edge (NVIDIA)";
    genericName = "Web Browser";
    comment = "Edge rendering on the NVIDIA GPU (own profile)";
    exec = "edge-nvidia %U";
    icon = "microsoft-edge";
    categories = [ "Network" "WebBrowser" ];
  };
in
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

  # ── Load i915 in initrd (early KMS), and ONLY i915.
  #
  # Background: an intermittent unbootable system. On 2026-08-11 boot
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
  # mid-load. Two drivers racing for the same DRM/vgaarb state. Boot then
  # *continued* with no nvidia_drm: sddm started, but the console had already
  # gone to "colour dummy device 80x25" — a black screen with a cursor that
  # looks like a TTY and accepts nothing.
  #
  # First fix attempt (ff9712c, builds 105–107) moved the whole list — i915 +
  # all four nvidia modules — into initrd. That made it strictly worse: insmod
  # returns as soon as the module is inserted, but i915 *probes* asynchronously
  # in a kworker, so the nvidia load started while i915 was still probing —
  # the exact same race, now inside initrd. Result (photo of the console):
  # "A start job is running for Load Kernel Modules (4min+ / 6min)", hung-task
  # warnings for two kworkers blocked on an rw-semaphore and
  # systemd-modules-load blocked behind them — an unrecoverable deadlock in
  # stage 1, and no journal survives to tell the tale.
  #
  # This is the corrected fix. i915 alone in initrd gets early KMS and, more
  # importantly, its probe runs and settles during stage 1 — long before
  # stage-2 systemd-modules-load touches the nvidia stack. The simultaneous-
  # probe window is closed without ever loading nvidia in initrd. Keeping
  # nvidia in stage 2 also keeps the 90s TimeoutStartSec safety net: if it
  # ever does block again, boot degrades instead of bricking.
  boot.initrd.kernelModules = [ "i915" ];

  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    modesetting.enable = true; # required for Wayland / KWin
    nvidiaSettings = true;

    # Open kernel modules — recommended on Turing and newer (GA107 qualifies)
    open = true;

    # Lets the dGPU fully power down when no offloaded client is running
    powerManagement.enable = true;
    powerManagement.finegrained = true;

    # Dynamic Boost (nvidia-powerd): lets the driver shift budget from an idle
    # CPU to the GPU, 60 W default -> 75 W max on this RTX 3050. The driver
    # reports "Notebook Dynamic Boost: Supported"; without the daemon the
    # extra 15 W is simply never offered.
    dynamicBoost.enable = true;

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

    edgeNvidia
    edgeNvidiaDesktop
  ];
}
