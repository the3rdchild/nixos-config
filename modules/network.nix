{ config, pkgs, ... }:
{
  networking.hostName = "noouoops";
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # FIX: Route NetworkManager DNS through systemd-resolved to prevent signature conflicts
  networking.networkmanager.dns = "systemd-resolved";
  services.resolved.enable = true;
  networking.firewall.allowedTCPPorts = [ 4321 ];
  networking.firewall.allowedUDPPorts = [ 4321 ];  # optional, untuk mDNS/SSDP discovery

  # WireGuard is now managed by NetworkManager (toggle from the Plasma system-tray
  # network applet, or `nmcli connection up wg0`). The connection profile is
  # imported once from /etc/wireguard/wg0.conf — see README migration notes.
  #
  # This replaces the old `networking.wg-quick.interfaces.wg0` block, which
  # conflicted with NetworkManager's interface lifecycle and left stale wg0
  # devices behind on failed starts ("wg0 already exists"). NetworkManager owns
  # the interface end-to-end, so restart/stop/start are all clean.
}
