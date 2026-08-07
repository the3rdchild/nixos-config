{ config, lib, pkgs, ... }:

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

  # ── warp: toggle Cloudflare WARP (1.1.1.1) manually.
  #
  # `services.cloudflare-warp.enable` starts `warp-svc`; this script is just a
  # thin switch so the CLI usage matches the existing `vpn` helper. Run
  # `warp-cli --accept-tos registration new` once before the first connect.
  #
  # WARP and the wg0 WireGuard tunnel both install full-tunnel policy rules, so
  # keep only one active at a time. Use `vpn` for wg0 and `warp` for WARP.
  warp = pkgs.writeShellScriptBin "warp" ''
    set -u
    warpcli=${pkgs.cloudflare-warp}/bin/warp-cli

    is_up() {
      $warpcli --accept-tos status 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -qi '^Status: Connected'
    }

    case "''${1-toggle}" in
      up|on)   $warpcli --accept-tos connect ;;
      down|off) $warpcli --accept-tos disconnect ;;
      toggle)  if is_up; then $warpcli --accept-tos disconnect; else $warpcli --accept-tos connect; fi ;;
      status)  $warpcli --accept-tos status ;;
      *)
        echo "usage: warp [up|down|toggle|status]" >&2
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

  # ── DNS: one resolver, no per-link anything.
  #
  # The bug this replaces: `nsswitch.conf` sends every glibc lookup to
  # systemd-resolved with `resolve [!UNAVAIL=return]`, so /etc/resolv.conf is
  # never consulted. resolved then prefers a *link-scoped* DNS server on the
  # default-route link over its Global config — so the DHCP-supplied
  # 10.116.173.225 (Telkomsel) won, `DNS=1.1.1.1` below was never reached, and
  # duckduckgo.com resolved to the internetbaik.telkomsel.com block page even
  # with WARP connected and healthy.
  #
  # `ipv4.ignore-auto-dns` in networking.networkmanager.connectionConfig did
  # NOT fix that: it lands in NetworkManager.conf's [connection] section, but
  # that section only honours NM's documented connection-default properties and
  # ignore-auto-dns is not one of them. `nmcli` reported it as "no" and NM kept
  # installing the DHCP server. It was silently a no-op — do not re-add it.
  #
  # dns="none" is the fix that generalises: NetworkManager stops touching
  # resolv.conf and stops calling SetLinkDNS entirely, so *no* interface —
  # wlp5s0, enp4s0, enp0s20f0u9, or any network joined in future — can inject a
  # resolver. resolved is left with only the global config below.
  #
  # Tailscale is unaffected: it configures its link (100.100.100.100 + ~ts.net
  # routing domains) directly over resolved's D-Bus API, not through NM, and a
  # specific routing domain still beats the "~." default route below. wg0 is
  # likewise untouched — it pushes no DNS.
  #
  # Trade-off accepted: captive-portal wifi (hotel/airport) will not resolve,
  # because there is no longer any path for a local network to supply a
  # resolver. Escape hatch: `sudo resolvectl dns <iface> <portal-dns>` for the
  # duration of the login, then `sudo resolvectl revert <iface>`.
  #
  # mkForce because nixos/modules/system/boot/resolved.nix hard-sets this to
  # "systemd-resolved" (not mkDefault) whenever services.resolved is enabled.
  networking.networkmanager.dns = lib.mkForce "none";

  services.resolved = {
    enable = true;
    # Strict DoT, with the server name attached so the certificate is actually
    # hostname-verified — plain "1.1.1.1" would leave resolved unable to check
    # who it is talking to. Strict (not opportunistic) is deliberate: on an ISP
    # that hijacks port 53, an opportunistic downgrade to plaintext hands the
    # hijacker the win. This fails closed instead.
    settings.Resolve = {
      DNSOverTLS = "true";
      DNSSEC = "false";
      # "~." makes the global config the default route for every name, so
      # nothing falls through to a link scope.
      Domains = "~.";
      # systemd ships compiled-in fallback resolvers (Cloudflare *and* Google)
      # that resolved uses whenever it thinks it has no DNS configured. Those
      # are plaintext :53 and would be a leak the moment DoT hiccups. Empty it.
      FallbackDNS = "";
    };
  };
  networking.nameservers = [
    "1.1.1.1#cloudflare-dns.com"
    "1.0.0.1#cloudflare-dns.com"
    "2606:4700:4700::1111#cloudflare-dns.com"
    "2606:4700:4700::1001#cloudflare-dns.com"
  ];

  networking.firewall.allowedTCPPorts = [ 4321 ];
  networking.firewall.allowedUDPPorts = [
    4321   # optional, untuk mDNS/SSDP discovery
  ];
  # (Removed: UDP 2408. It was inbound-only and WARP is on MASQUE — HTTP/3 over
  # UDP 443 outbound — so the rule matched nothing either way.)

  # ── DNS leak guard: no plaintext :53 leaves this box.
  #
  # The config above is the real fix; this is the backstop that makes a
  # regression fail loudly instead of silently returning a block page — which
  # is exactly how the original leak stayed hidden. Anything with a hardcoded
  # resolver (8.8.8.8 baked into an app, a DHCP hook, a future misconfig) hits
  # this and errors out rather than quietly talking to the ISP.
  #
  # REJECT, not DROP: callers fail immediately with a visible error instead of
  # hanging for a timeout.
  #
  # Allowed through: loopback (resolved's own stub, and WARP's local proxy on
  # 127.0.2.2/127.0.2.3), Tailscale MagicDNS, and anything already inside the
  # WARP or wg0 tunnels — traffic there is encrypted before it reaches the ISP.
  # Normal operation never trips this at all, since strict DoT uses tcp/853.
  networking.firewall.extraCommands = ''
    # v4
    iptables -w -N dns-leak-guard 2>/dev/null || iptables -w -F dns-leak-guard
    iptables -w -A dns-leak-guard -o lo -j RETURN
    iptables -w -A dns-leak-guard -d 127.0.0.0/8 -j RETURN
    iptables -w -A dns-leak-guard -d 100.100.100.100 -j RETURN
    for dev in CloudflareWARP tailscale0 wg0; do
      iptables -w -A dns-leak-guard -o "$dev" -j RETURN
    done
    iptables -w -A dns-leak-guard -p udp -j REJECT --reject-with icmp-port-unreachable
    iptables -w -A dns-leak-guard -p tcp -j REJECT --reject-with tcp-reset
    for proto in udp tcp; do
      iptables -w -C OUTPUT -p $proto --dport 53 -j dns-leak-guard 2>/dev/null \
        || iptables -w -I OUTPUT -p $proto --dport 53 -j dns-leak-guard
    done

    # v6
    ip6tables -w -N dns-leak-guard 2>/dev/null || ip6tables -w -F dns-leak-guard
    ip6tables -w -A dns-leak-guard -o lo -j RETURN
    ip6tables -w -A dns-leak-guard -d ::1/128 -j RETURN
    ip6tables -w -A dns-leak-guard -d fd7a:115c:a1e0::53/128 -j RETURN
    for dev in CloudflareWARP tailscale0 wg0; do
      ip6tables -w -A dns-leak-guard -o "$dev" -j RETURN
    done
    ip6tables -w -A dns-leak-guard -p udp -j REJECT --reject-with icmp6-port-unreachable
    ip6tables -w -A dns-leak-guard -p tcp -j REJECT --reject-with tcp-reset
    for proto in udp tcp; do
      ip6tables -w -C OUTPUT -p $proto --dport 53 -j dns-leak-guard 2>/dev/null \
        || ip6tables -w -I OUTPUT -p $proto --dport 53 -j dns-leak-guard
    done
  '';
  networking.firewall.extraStopCommands = ''
    for proto in udp tcp; do
      iptables  -w -D OUTPUT -p $proto --dport 53 -j dns-leak-guard 2>/dev/null || true
      ip6tables -w -D OUTPUT -p $proto --dport 53 -j dns-leak-guard 2>/dev/null || true
    done
    iptables  -w -F dns-leak-guard 2>/dev/null || true
    iptables  -w -X dns-leak-guard 2>/dev/null || true
    ip6tables -w -F dns-leak-guard 2>/dev/null || true
    ip6tables -w -X dns-leak-guard 2>/dev/null || true
  '';

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

  environment.systemPackages = [ vpn wg0-purge warp ];

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
