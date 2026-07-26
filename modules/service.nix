{ pkgs, ... }:
{
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;
  services.printing.enable = true;
  services.openssh.enable = true;
  services.cloudflare-warp.enable = true;
}
