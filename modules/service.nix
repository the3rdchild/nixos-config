{ ... }:
{
  # NOTE: SDDM is configured in ./sddm.nix, not here — including the display
  # server mode and greeter compositor that services.desktopManager.plasma6
  # used to set on our behalf.
  #
  # No desktop manager is enabled any more. Hyprland is the only session, and
  # it comes from programs.hyprland in ./package.nix.
  services.printing.enable = true;
  services.openssh.enable = true;
  services.cloudflare-warp.enable = true;
  services.flatpak.enable = true;
  services.tailscale.enable = true;
  services.locate.enable = true;

  # Was on via plasma6's mkDefault and went away with it. Nothing else here
  # depends on it — `fwupdmgr` is a CLI, so it costs nothing to keep and is
  # the only firmware update path on this laptop. Drop the line if unwanted.
  services.fwupd.enable = true;
}
