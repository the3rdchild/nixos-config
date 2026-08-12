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
  #
  # WARP never comes up on its own — see warp-no-autoconnect below. You must
  # run `warp up` after every boot. DNS does not depend on this: resolved talks
  # Cloudflare over DoT whether the tunnel is up or down.
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

  # ── portal-guard: the root half of the captive-portal escape hatch.
  #
  # The DNS config below is deliberately airtight: global DoT to Cloudflare,
  # "~." so nothing falls through to a link scope, and dns-leak-guard REJECTing
  # every port-53 packet that is not headed for loopback or a tunnel. That is
  # correct for normal operation and fatal for a captive portal, which needs a
  # plaintext lookup against the *local* resolver before it will let you log in.
  #
  # The escape hatch this file used to document — `resolvectl dns <iface> <ip>`
  # — never actually worked: it fixes resolved and then the packet still dies in
  # dns-leak-guard, because that chain does not care who asked. Both halves have
  # to move together, which is why this is a script and not a note in a comment.
  #
  # Four things are needed, and missing any one of them leaves you with a portal
  # that still will not resolve:
  #
  #   1. A hole in dns-leak-guard for exactly the portal's resolvers, scoped to
  #      the interface they live on. Tagged with an iptables comment so `off`
  #      can find and remove them without trusting a state file.
  #   2. The resolvers installed on the link. NM already does this even with
  #      dns="none" (see the note there) but we do not depend on that.
  #   3. Routing domain "~." on the link. Without it the global "~." keeps
  #      winning and the link servers are never consulted. Both scopes match
  #      after this; resolved queries them in parallel and takes the first
  #      answer, so the (blocked, timing-out) global one costs nothing.
  #   4. DNSOverTLS=no on the link. The global "true" propagates down, and no
  #      hotel gateway on earth speaks DoT on 853.
  #
  # Fail-safe: this weakens the leak guard, so `on` arms a transient systemd
  # timer that reverts everything unattended. Forgetting to run `portal off` is
  # the expected case, not the exceptional one — the hole closes on its own.
  portal-guard = pkgs.writeShellScriptBin "portal-guard" ''
    set -u
    ipt=${pkgs.iptables}/bin/iptables
    ipt6=${pkgs.iptables}/bin/ip6tables
    resolvectl=${pkgs.systemd}/bin/resolvectl
    systemd_run=${pkgs.systemd}/bin/systemd-run
    systemctl=${pkgs.systemd}/bin/systemctl
    grep=${pkgs.gnugrep}/bin/grep
    sed=${pkgs.gnused}/bin/sed

    chain=dns-leak-guard
    tag=portal-guard
    unit=portal-guard-revert
    statefile=/run/portal-guard.iface

    # $0 is the absolute store path under sudo, which is how the auto-revert
    # timer re-enters this script. Nix cannot reference a derivation from inside
    # its own text, so self-reference has to go through argv.
    self="$0"

    die() { echo "portal-guard: $*" >&2; exit 1; }

    is_v6() { case "$1" in *:*) return 0 ;; *) return 1 ;; esac; }

    # Drop every rule we ever added, both families. `-D` removes one match per
    # call and there is one rule per resolver, so loop until the chain is clean.
    purge_rules() {
      for t in "$ipt" "$ipt6"; do
        while :; do
          spec=$($t -w -S "$chain" 2>/dev/null | $grep -m1 -- "--comment $tag" || true)
          [ -n "$spec" ] || break
          $t -w $(echo "$spec" | $sed 's/^-A /-D /') 2>/dev/null || break
        done
      done
    }

    case "''${1-}" in
      on)
        iface=''${2-}
        ttl=''${3-}
        [ -n "$iface" ] && [ -n "$ttl" ] || die "usage: portal-guard on <iface> <ttl-seconds> <resolver>..."
        shift 3
        [ "$#" -gt 0 ] || die "no resolvers given"
        [ -e "/sys/class/net/$iface" ] || die "no such interface: $iface"
        case "$ttl" in *[!0-9]*|"") die "ttl must be seconds, got: $ttl" ;; esac

        # Start from a clean slate: re-running `on` for a different network must
        # not leave the previous network's hole open.
        purge_rules

        for r in "$@"; do
          # These land in an iptables command line. Refuse anything that is not
          # a bare IP literal rather than letting a hostname or a shell
          # metacharacter through.
          case "$r" in
            ""|*[!0-9a-fA-F.:]*) die "not an IP literal: $r" ;;
          esac
          if is_v6 "$r"; then t=$ipt6; else t=$ipt; fi
          $t -w -I "$chain" 1 -o "$iface" -d "$r" \
             -m comment --comment "$tag" -j RETURN \
            || die "could not open $chain for $r — is firewall.service up?"
        done

        $resolvectl dns "$iface" "$@"
        $resolvectl domain "$iface" "~."
        $resolvectl dnsovertls "$iface" no
        $resolvectl default-route "$iface" yes
        $resolvectl flush-caches
        echo "$iface" > "$statefile"

        $systemctl stop "$unit.timer" 2>/dev/null || true
        $systemd_run --quiet --collect --unit="$unit" --on-active="$ttl" \
          "$self" off "$iface" \
          || echo "portal-guard: WARNING auto-revert timer failed to arm — run \`portal off\` yourself" >&2

        echo "portal-guard: $iface -> $* (plaintext :53, reverts in ''${ttl}s)"
        ;;

      off)
        iface=''${2-}
        [ -n "$iface" ] || iface=$(cat "$statefile" 2>/dev/null || true)
        purge_rules
        $systemctl stop "$unit.timer" 2>/dev/null || true
        if [ -n "$iface" ]; then
          $resolvectl revert "$iface" 2>/dev/null || true
        fi
        $resolvectl flush-caches
        rm -f "$statefile"
        echo "portal-guard: reverted''${iface:+ ($iface)} — strict DoT restored"
        ;;

      status)
        iface=$(cat "$statefile" 2>/dev/null || true)
        if [ -z "$iface" ]; then
          echo "portal: off"
        else
          echo "portal: ON for $iface"
          echo
          echo "--- auto-revert ---"
          $systemctl list-timers --all "$unit.timer" --no-pager 2>/dev/null | $grep -v '^$' || true
          echo
          echo "--- resolved ---"
          $resolvectl status "$iface" 2>/dev/null || true
        fi
        echo
        echo "--- $chain holes ---"
        for t in "$ipt" "$ipt6"; do
          $t -w -S "$chain" 2>/dev/null | $grep -- "--comment $tag" || true
        done
        ;;

      *)
        echo "usage: portal-guard [on <iface> <ttl-seconds> <resolver>...|off [iface]|status]" >&2
        exit 2
        ;;
    esac
  '';

  # ── portal: the user-facing half. `portal on` … log in … `portal off`.
  #
  # Everything here runs unprivileged: pick the interface, ask NM what the
  # network offered for DNS, hand both to portal-guard through the scoped
  # NOPASSWD rule at the bottom of this file.
  #
  # We read the resolvers from NetworkManager rather than /etc/resolv.conf
  # because resolv.conf only ever contains resolved's stub (127.0.0.53). NM
  # keeps the DHCP-supplied servers in its own state whether or not it is
  # allowed to publish them, which is exactly what we want.
  portal = pkgs.writeShellScriptBin "portal" ''
    set -u
    nmcli=${pkgs.networkmanager}/bin/nmcli
    ip=${pkgs.iproute2}/bin/ip
    curl=${pkgs.curl}/bin/curl
    grep=${pkgs.gnugrep}/bin/grep
    sed=${pkgs.gnused}/bin/sed
    sort=${pkgs.coreutils}/bin/sort
    head=${pkgs.coreutils}/bin/head
    tr=${pkgs.coreutils}/bin/tr
    awk=${pkgs.gawk}/bin/awk
    guard="/run/wrappers/bin/sudo -n ${portal-guard}/bin/portal-guard"

    # Long enough to find the login page, fumble the password, and read the
    # terms nobody reads.
    #
    # The TTL used to be PORTAL_TTL_MIN only, which was a bad interface on this
    # machine: the login shell is fish, and fish rejects the `VAR=x cmd` prefix
    # outright —
    #
    #   fish: Unsupported use of '='. In fish, please use 'set PORTAL_TTL_MIN 1'.
    #
    # so the documented way to change the timeout did not work in the shell it
    # was documented for. It is a positional argument now and the env var is
    # kept only as a fallback. `env PORTAL_TTL_MIN=1 portal …` still works too.
    ttl_min=''${PORTAL_TTL_MIN-20}

    die() { echo "portal: $*" >&2; exit 1; }

    case "''${1-status}" in
      on|up)
        shift
        # Both remaining arguments are optional and order does not matter: an
        # all-digits one is minutes, anything else is an interface name. No
        # interface is called "45" and no timeout is called "wlp5s0", so this
        # cannot be ambiguous, and it saves having to remember which comes
        # first at the exact moment you are standing in a lobby with no DNS.
        for a in "$@"; do
          case "$a" in
            "")        ;;
            *[!0-9]*)  iface=$a ;;
            *)         ttl_min=$a ;;
          esac
        done

        if [ -z "''${iface-}" ]; then
          # Lowest-metric default route: the link actually carrying traffic.
          iface=$($ip -4 route show default | $sort -k9 -n | $head -1 | $awk '{print $5}')
        fi
        [ -n "$iface" ] || die "no default route — pass the interface: portal on wlp5s0"
        [ "$ttl_min" -gt 0 ] 2>/dev/null || die "minutes must be a positive number, got: $ttl_min"

        resolvers=$($nmcli dev show "$iface" 2>/dev/null \
          | $grep -E '^IP[46]\.DNS\[' | $sed 's/.*: *//')
        if [ -z "$resolvers" ]; then
          # Some portals hand out no DNS at all and answer on the gateway.
          resolvers=$($nmcli dev show "$iface" 2>/dev/null \
            | $grep -E '^IP4\.GATEWAY' | $sed 's/.*: *//' | $grep -v '^--$' || true)
        fi
        [ -n "$resolvers" ] || die "$iface was offered no DNS server and has no gateway"

        $guard on "$iface" "$((ttl_min * 60))" $resolvers || exit 1

        # Ask a known-204 endpoint where it gets bounced to. Keep the body: a
        # well-behaved portal 302s and curl hands us the Location, but FortiGate
        # — which is what Unpad runs — answers 200 with a JavaScript bounce:
        #
        #   <script>window.location="https://pintas.unpad.ac.id:1003/fgtauth?<tok>";</script>
        #
        # so redirect_url is empty and the only copy of the URL is in the HTML.
        # Checking the header alone reports "no redirect seen" on exactly the
        # portal we wrote this for. Check both.
        echo
        resp=$($curl -sS --interface "$iface" -m 8 \
          -w "\nX-REDIRECT:%{redirect_url}\n" \
          http://connectivitycheck.gstatic.com/generate_204 2>/dev/null || true)

        url=$(printf '%s\n' "$resp" | $sed -n 's/^X-REDIRECT:\(..*\)/\1/p' | $head -1)
        if [ -z "$url" ]; then
          # Normalise quoting so one pattern catches window.location='…',
          # window.location="…" and <meta http-equiv=refresh content="0;url=…">.
          url=$(printf '%s\n' "$resp" | $tr "\047" '"' \
            | $grep -oE 'https?://[^" <>]+' \
            | $grep -v 'gstatic\.com' \
            | $head -1 || true)
        fi

        if [ -n "$url" ]; then
          echo "portal: log in at $url"
          # The fgtauth token is per-session and dies with the association, so
          # this URL is only good for this attempt. Re-run `portal on` to mint
          # a fresh one rather than bookmarking it.
        else
          echo "portal: no redirect seen — open http://neverssl.com in a browser"
        fi
        echo "portal: when you are through, run \`portal off\`"
        ;;

      off|down)
        $guard off "''${2-}"
        ;;

      status)
        $guard status
        ;;

      *)
        echo "usage: portal [on [iface] [minutes]|off [iface]|status]" >&2
        echo "       portal on wlp5s0 45   # 45-minute window on a slow portal" >&2
        echo "       default window: $ttl_min min" >&2
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
  # resolv.conf, so no DHCP-supplied resolver can reach a glibc lookup that way.
  #
  # Note what it does NOT do, because the earlier version of this comment had it
  # wrong: dns="none" does not stop SetLinkDNS. That push is controlled by a
  # separate knob, `[main] systemd-resolved`, which defaults to true and is not
  # set here — so NM still installs the DHCP servers as a *link* scope, and
  # `resolvectl status wlp5s0` shows them sitting there right now. What actually
  # keeps them from being used is Domains="~." below, which makes the global
  # config the default route for every name so a bare link scope with no routing
  # domain never matches, plus dns-leak-guard, which drops the packet even if
  # something did route to it. Two independent layers, neither of them dns=none.
  #
  # Tailscale is unaffected: it configures its link (100.100.100.100 + ~ts.net
  # routing domains) directly over resolved's D-Bus API, not through NM, and a
  # specific routing domain still beats the "~." default route below. wg0 is
  # likewise untouched — it pushes no DNS.
  #
  # Trade-off: captive-portal wifi (hotel/airport/campus guest) will not
  # resolve, because nothing here lets a local network supply a resolver.
  #
  # Escape hatch: `portal on` … log in … `portal off`. The old note here said to
  # use `resolvectl dns <iface> <portal-dns>` directly; that is not enough and
  # never was — it fixes resolved, then dns-leak-guard rejects the packet
  # anyway. See the portal-guard script above for the four things that actually
  # have to change together.
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

  # ── Reverse-path filtering: loose, not strict.
  #
  # NixOS defaults networking.firewall.checkReversePath to true, which emits
  #
  #   iptables -t mangle -A nixos-fw-rpfilter -m rpfilter --validmark -j RETURN
  #   iptables -t mangle -A nixos-fw-rpfilter -j DROP
  #
  # with no --loose. Strict rpfilter drops any packet arriving on an interface
  # that is not the one the kernel would use to route back to that packet's
  # source. On a single-homed box that is free anti-spoofing. On this one it is
  # a trap, because two default routes are normal here: wifi plus a USB tether,
  # or wifi plus ethernet.
  #
  # What it cost: with the tether up at metric 100 and UnpadWiFiGuest at 600,
  # every reply arriving on wlp5s0 from anything outside 10.92.48.0/21 had a
  # reverse path pointing at the tether, so the kernel dropped it in PREROUTING
  # before any socket saw it. The wifi looked dead in the most misleading way
  # possible — ARP and ICMP to the gateway fine (its route *is* on wlp5s0), and
  # absolutely nothing else, including the captive portal redirect. It reads
  # exactly like "the network blocked my MAC", which is where three hours went.
  #
  # Note that the sysctls are a red herring: net.ipv4.conf.*.rp_filter is
  # already 2 (loose) here, and it does not matter. The -m rpfilter match is an
  # independent implementation and it was the strict one.
  #
  # "loose" keeps the part worth keeping — the source still has to be reachable
  # via *some* interface, so spoofed martians are still dropped — while letting
  # a multi-homed box answer on the interface a packet actually arrived on.
  # This is also what the NixOS option's own docs recommend as soon as
  # NetworkManager or a VPN is in the picture, and both are, above.
  networking.firewall.checkReversePath = "loose";

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

  # ── WARP must NOT auto-connect.
  #
  # Same problem as wg0, different mechanism. WARP's autoconnect is *stateful*,
  # not configured: `warp-cli connect` writes `always_on: true` into
  # /var/lib/cloudflare-warp/settings.json, and warp-svc then re-establishes
  # the tunnel on every boot. `warp-cli disconnect` writes it back to false.
  # There is no declarative knob — this warp-cli build's `settings` subcommand
  # only has list/reset/support-url/mode-switch-allowed, no `set always-on`.
  #
  # So the state is only ever as sticky as whatever you did last, which means a
  # single `warp up` silently turns WARP into a boot-time tunnel forever. This
  # oneshot re-asserts "disconnected" at every boot, making `warp up` an
  # explicit, per-session action.
  #
  # The daemon itself is left running (services.cloudflare-warp.enable in
  # modules/service.nix) so `warp up` stays instant and needs no root — an
  # idle warp-svc creates no interface and no policy rules; `CloudflareWARP`
  # only appears on connect.
  systemd.services.warp-no-autoconnect = {
    description = "Leave Cloudflare WARP disconnected at boot (connect with `warp up`)";
    after = [ "cloudflare-warp.service" ];
    wants = [ "cloudflare-warp.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      warpcli=${pkgs.cloudflare-warp}/bin/warp-cli

      # warp-svc opens its IPC socket a beat after the unit reports started.
      # Without this wait the disconnect hits a dead socket, fails silently,
      # and WARP comes up connected anyway — the exact bug we're fixing.
      for _ in $(${pkgs.coreutils}/bin/seq 30); do
        $warpcli --accept-tos status >/dev/null 2>&1 && break
        ${pkgs.coreutils}/bin/sleep 1
      done

      # Tolerate failure: already-disconnected is the common case and is not an
      # error worth failing the boot over.
      $warpcli --accept-tos disconnect >/dev/null 2>&1 || true
      echo "warp: $($warpcli --accept-tos status 2>&1 | ${pkgs.coreutils}/bin/head -1)"
    '';
  };

  environment.systemPackages = [ vpn wg0-purge warp portal portal-guard ];

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
        # Same reasoning as wg0-purge: `portal` needs iptables and resolvectl
        # link surgery, and it has to work from a laptop that currently cannot
        # resolve anything, so prompting is a bad time. Scoped to the one store
        # path, which changes on every rebuild that changes the script — the
        # rule cannot outlive the binary it names. portal-guard validates its
        # own arguments (IP literals only) rather than trusting the caller.
        {
          command = "${portal-guard}/bin/portal-guard";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
