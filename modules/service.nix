{ pkgs, ... }:
{
  # NOTE: SDDM is configured in ./sddm.nix, not here — including the display
  # server mode and greeter compositor that services.desktopManager.plasma6
  # used to set on our behalf.
  #
  # No desktop manager is enabled any more. Hyprland is the only session, and
  # it comes from programs.hyprland in ./package.nix.
  services.printing.enable = true;
  services.openssh.enable = true;

  # raspi-server is reachable from anywhere via its Cloudflare Tunnel, behind
  # Cloudflare Access. `ssh noouoops@ssh.noouoops.my.id` opens a browser for
  # the Access (email PIN) login the first time, then reuses the token.
  # On the LAN/tailnet, 192.168.100.200 / 100.120.32.64 need none of this.
  environment.systemPackages = [ pkgs.cloudflared ];
  programs.ssh.extraConfig = ''
    Host ssh.noouoops.my.id
      ProxyCommand ${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h
  '';
  services.cloudflare-warp.enable = true;
  services.flatpak.enable = true;
  services.tailscale.enable = true;
  services.locate.enable = true;

  # Was on via plasma6's mkDefault and went away with it. Nothing else here
  # depends on it — `fwupdmgr` is a CLI, so it costs nothing to keep and is
  # the only firmware update path on this laptop. Drop the line if unwanted.
  services.fwupd.enable = true;
}
