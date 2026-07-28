{ config, pkgs, ... }:

let
  # ── wg0-purge: tear down every trace of a wireguard tunnel.
  #
  # Both wg-quick and NetworkManager implement a full-tunnel by installing the
  # same pair of policy rules:
  #
  #   not from all fwmark <mark> lookup <table>    ← unmarked traffic → tunnel
  #   from all lookup main suppress_prefixlength 0 ← hide main's default route
  #
  # Neither cleans up after the other, and the second rule is the dangerous
  # one: it hides the real default route from every lookup at that priority.
  # Left behind with no tunnel to catch the traffic, it blackholes the box —
  # loopback still pings, nothing else resolves or connects.
  #
  # This runs only when we intend *no* tunnel to exist, so anything matching is
  # by definition stale and safe to delete.
  wg0-purge = pkgs.writeShellScriptBin "wg0-purge" ''
    set -u
    ip=${pkgs.iproute2}/bin/ip

    # 1. Leftover devices. NM only auto-deletes interfaces it created itself;
    #    one wg-quick made (and NM then adopted as "connected (externally)")
    #    survives `nmcli connection down` and keeps attracting traffic.
    for dev in $($ip -br link show type wireguard 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $1}'); do
      echo "wg0-purge: removing leftover device $dev"
      $ip link del "$dev" 2>/dev/null || true
    done

    # 2. Stale policy rules, v4 and v6. Repeat the sweep: duplicates can share a
    #    priority and `ip rule del` only removes one match per call.
    for family in -4 -6; do
      for _pass in 1 2 3; do
        for prio in $($ip $family rule show 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep -E 'suppress_prefixlength 0|lookup 51820|lookup 51895' \
              | ${pkgs.coreutils}/bin/cut -d: -f1); do
          echo "wg0-purge: dropping stale ip rule at priority $prio ($family)"
          $ip $family rule del priority "$prio" 2>/dev/null || true
        done
      done
    done

    # 3. Empty the tunnel tables. Routes bound to a deleted device go away on
    #    their own; this catches anything that outlived it.
    for table in 51820 51895; do
      $ip -4 route flush table "$table" 2>/dev/null || true
      $ip -6 route flush table "$table" 2>/dev/null || true
    done

    # 4. wg-quick's fwmark chains, if it ever ran on this boot.
    ${pkgs.nftables}/bin/nft delete table ip wg-quick-wg0 2>/dev/null || true
    ${pkgs.nftables}/bin/nft delete table ip6 wg-quick-wg0 2>/dev/null || true

    echo "wg0-purge: done"
  '';

  # ── vpn: the on/off switch.
  #
  # Always drive the tunnel through this, never `wg-quick` — mixing the two on
  # one interface is what produced the stale-rule blackhole in the first place.
  # `up` purges before connecting (old rules sit at a *lower* priority than
  # NM's fresh ones, so they win); `down` purges after, because NM leaves the
  # device behind whenever it didn't create it.
  vpn = pkgs.writeShellScriptBin "vpn" ''
    set -u
    nmcli=${pkgs.networkmanager}/bin/nmcli
    purge="/run/wrappers/bin/sudo -n ${wg0-purge}/bin/wg0-purge"
    conn=wg0

    is_up() {
      $nmcli -t -f NAME connection show --active 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -qx "$conn"
    }

    vpn_up() {
      $purge >/dev/null
      $nmcli connection up "$conn"
    }

    vpn_down() {
      $nmcli connection down "$conn" || true
      $purge >/dev/null
      echo "Connection '$conn' deactivated"
    }

    case "''${1-toggle}" in
      up|on)   vpn_up ;;
      down|off) vpn_down ;;
      toggle)  if is_up; then vpn_down; else vpn_up; fi ;;
      status)
        if is_up; then echo "wg0: connected"; else echo "wg0: disconnected"; fi
        echo
        echo "--- ip rule ---"
        ${pkgs.iproute2}/bin/ip rule show
        ;;
      *)
        echo "usage: vpn [up|down|toggle|status]" >&2
        exit 2
        ;;
    esac
  '';
in
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

  # WireGuard is now managed by NetworkManager. Toggle it with `vpn on` /
  # `vpn off` / `vpn toggle` (see the script above), or from the network applet.
  # The connection profile is imported once from /etc/wireguard/wg0.conf — see
  # README migration notes.
  #
  # Do NOT use `wg-quick up/down wg0` anymore. It installs a second, competing
  # set of policy rules on the same interface at a lower priority than NM's;
  # when either side goes down the other's rules survive and blackhole all
  # traffic. `vpn` + wg0-purge exist precisely to keep that from happening.
  #
  # This replaces the old `networking.wg-quick.interfaces.wg0` block, which
  # conflicted with NetworkManager's interface lifecycle and left stale wg0
  # devices behind on failed starts ("wg0 already exists"). NetworkManager owns
  # the interface end-to-end, so restart/stop/start are all clean.

  # ── wg0 must NOT auto-connect.
  #
  # The imported wg0 profile defaults to autoconnect=yes, which brings the
  # full-tunnel VPN up on every boot / WiFi reconnect — not what we want. We
  # only connect it manually (nmcli / caelestia network applet).
  #
  # The setting lives in NM's mutable state, so this oneshot re-applies it
  # after NM starts. Idempotent and fail-safe: if the wg0 profile doesn't
  # exist yet (not imported), there is nothing to iterate over and we exit 0
  # rather than failing the boot.
  #
  # Iterate by UUID, not by name: re-importing wg0.conf creates a *second*
  # profile also called wg0, and `nmcli connection modify wg0` only ever
  # touches the first match — which is how one wg0 ended up pinned to
  # autoconnect=no while its twin still came up on every boot.
  systemd.services.wg0-no-autoconnect = {
    description = "Disable autoconnect on every wg0 WireGuard profile";
    after = [ "NetworkManager.service" ];
    wants = [ "NetworkManager.service" ];
    # type=oneshot + remainExit so a failure is visible, but we exit 0 on
    # "profile missing" (transient — it gets imported later) so boot isn't blocked.
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      nmcli=${pkgs.networkmanager}/bin/nmcli
      found=0
      for uuid in $($nmcli -t -f UUID,NAME connection show 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep ':wg0$' \
            | ${pkgs.coreutils}/bin/cut -d: -f1); do
        $nmcli connection modify uuid "$uuid" connection.autoconnect no \
          && echo "wg0: autoconnect disabled on $uuid"
        found=1
      done
      [ "$found" = 1 ] || echo "wg0: profile not found yet — skipping (will retry)"
    '';
  };
  systemd.timers.wg0-no-autoconnect = {
    # Re-assert periodically too: re-importing the profile (e.g. from a fresh
    # /etc/wireguard/wg0.conf) resets autoconnect to yes. 5 min after boot,
    # then daily, keeps it pinned without thrashing.
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1d";
    };
  };

  environment.systemPackages = [ vpn wg0-purge ];

  # `nmcli up/down` is already passwordless for the networkmanager group, but
  # the rule/link surgery in wg0-purge needs root. Scope the exemption to that
  # one store path so `vpn toggle` can run unattended (keybind, applet) without
  # handing wheel a blanket NOPASSWD. The path changes on every rebuild that
  # changes the script, so the rule can't outlive the binary it names.
  security.sudo.extraRules = [
    {
      groups = [ "wheel" ];
      commands = [
        {
          command = "${wg0-purge}/bin/wg0-purge";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
