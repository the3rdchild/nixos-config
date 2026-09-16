{ config, lib, pkgs, ... }:

# ── Mobile hotspot: share this laptop's uplink over Wi-Fi while the Wi-Fi is
# itself connected. The Windows 11 "Mobile hotspot" feature, on NixOS.
#
# How it works, and why it is shaped like this:
#
# The AX210 (iwlwifi) advertises this interface combination in `iw list`:
#
#   #{ managed } <= 1, #{ AP, P2P-client, P2P-GO } <= 1, #{ P2P-device } <= 1,
#   total <= 3, #channels <= 1
#
# so one station and one AP can run on the same radio, provided they share a
# channel. The AP needs its own virtual interface, created by `hotspot-guard`
# with `iw ... interface add ap0 type __ap`.
#
# Why NetworkManager does NOT run the AP (first attempt, reverted):
# nm-device-wifi.c deactivate() — which also runs when NM first takes a wifi
# device — forces the device back to infrastructure mode and brings it up.
# Two stations on this radio is exactly what the combination above forbids,
# so the bring-up fails with EBUSY, wpa_supplicant cannot grab the interface,
# and ap0 never becomes "available" for the AP profile. Hence ap0 is
# `unmanaged` for NM and the AP is hostapd, which sets AP mode itself.
# hostapd, a private dnsmasq (DHCP + DNS forwarder) and an nftables NAT table
# are the same three pieces NM's shared mode would have used, just driven
# from hotspot-guard as transient systemd units.
#
# The `#channels <= 1` rule is enforced by the kernel: an AP on a different
# channel from the station fails. `hotspot on` reads the station's channel and
# hands it to hostapd. When that still fails — the station is on a DFS channel
# (52–144), where AP mode is never allowed on this card — it re-pins the Wi-Fi
# profile to 2.4 GHz, reconnects, and tries once more. The pin is undone by
# `hotspot off`.
#
# DNS: dnsmasq on 10.42.0.1 forwards to systemd-resolved's stub, so client
# lookups ride the same strict-DoT path as the host's. Client packets aimed at
# any other :53 are DNAT'ed to 10.42.0.1 — dns-leak-guard in ./network.nix only
# covers OUTPUT, and forwarded plaintext DNS from a phone would otherwise walk
# straight past it. Forwarded client traffic is unmarked, so when wg0 is up the
# policy rule sends it through the tunnel like everything else.
#
# What needs root is everything on the system side (interface, hostapd,
# dnsmasq, nft), so that lives in hotspot-guard behind a store-path-scoped
# NOPASSWD rule — the same shape as wg0-purge and portal-guard in
# ./network.nix. SSID and passphrase are the user's: kept in
# ~/.config/hotspot/config (mode 600) and handed to the guard on stdin, never
# on the command line.
#
# ── wpa_supplicant: upstream-style D-Bus unit instead of NixOS's module.
#
# nixpkgs' networkmanager module enables networking.wireless in
# "dbusControlled" mode, and that module installs a udev rule that
# `try-restart`s wpa_supplicant whenever any wlan interface appears or
# disappears (it exists for the auto-detect mode, but is emitted whenever
# `interfaces` is empty). Creating ap0 therefore restarted wpa_supplicant,
# which dropped wlp5s0 for ~20 s every time the hotspot went on or off. NM
# only ever talks to wpa_supplicant over D-Bus and adds interfaces itself, so
# the module buys nothing here. The unit below is upstream's
# wpa_supplicant.service; the package already ships the matching D-Bus
# activation file.

let
  apIface = "ap0";
  apAddr = "10.42.0.1";
  apNet = "10.42.0.0/24";
  runDir = "/run/hotspot";

  # ── hotspot-guard: the root half.
  #
  #   hotspot-guard up <station-iface> <band a|bg> <channel>   (ssid, psk on stdin)
  #   hotspot-guard down <station-iface>
  hotspot-guard = pkgs.writeShellScriptBin "hotspot-guard" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.gnused ]}
    iw=${pkgs.iw}/bin/iw
    ip=${pkgs.iproute2}/bin/ip
    nft=${pkgs.nftables}/bin/nft
    systemctl=${pkgs.systemd}/bin/systemctl
    systemd_run=${pkgs.systemd}/bin/systemd-run
    journalctl=${pkgs.systemd}/bin/journalctl
    ap=${apIface}
    run=${runDir}

    die() { echo "hotspot-guard: $*" >&2; exit 1; }

    sta="''${2-}"
    if [ -n "$sta" ] || [ "''${1-}" = up ]; then
      [[ "$sta" =~ ^[a-z0-9]+$ ]] || die "bad interface name"
      [ -d "/sys/class/net/$sta/wireless" ] || die "$sta is not a wireless interface"
    fi

    # Restore whatever ./power.nix asked NetworkManager for.
    powersave=${if config.networking.networkmanager.wifi.powersave then "on" else "off"}

    stop_units() {
      for u in hotspot-hostapd hotspot-dnsmasq; do
        $systemctl stop "$u.service" 2>/dev/null || true
        $systemctl reset-failed "$u.service" 2>/dev/null || true
      done
    }

    teardown() {
      stop_units
      $nft delete table inet hotspot 2>/dev/null || true
      if [ -d "/sys/class/net/$ap" ]; then
        $iw dev "$ap" del 2>/dev/null || true
      fi
      [ -n "$sta" ] && $iw dev "$sta" set power_save "$powersave" 2>/dev/null
      rm -f "$run/hostapd.conf"
    }

    case "''${1-}" in
      up)
        band="''${3-}"; chan="''${4-}"
        [[ "$band" == a || "$band" == bg ]] || die "bad band"
        [[ "$chan" =~ ^[0-9]{1,3}$ ]] && [ "$chan" -ge 1 ] || die "bad channel"
        IFS= read -r ssid || die "no ssid on stdin"
        IFS= read -r psk || die "no passphrase on stdin"
        n=$(printf '%s' "$ssid" | ${pkgs.coreutils}/bin/wc -c)
        [ "$n" -ge 1 ] && [ "$n" -le 32 ] || die "ssid must be 1–32 bytes"
        [[ "$ssid" != *[[:cntrl:]]* ]] || die "ssid contains control characters"
        [[ "$psk" =~ ^[[:print:]]{8,63}$ ]] || die "passphrase must be 8–63 printable ASCII characters"

        # Always start clean: a leftover ap0 or a failed unit from a previous
        # run would otherwise make hostapd/systemd-run fail confusingly.
        teardown
        mkdir -p "$run/hostapd"
        chmod 755 "$run"

        # Locally-administered MAC derived from the station's: set the local
        # bit, flip the low bit of the last octet so it never collides with
        # the station itself.
        IFS=: read -r o1 o2 o3 o4 o5 o6 < "/sys/class/net/$sta/address"
        o1=$(printf '%02x' $(( 0x$o1 | 0x02 )))
        o6=$(printf '%02x' $(( 0x$o6 ^ 0x01 )))
        $iw dev "$sta" interface add "$ap" type __ap addr "$o1:$o2:$o3:$o4:$o5:$o6" \
          || die "could not create $ap on $sta"
        $ip addr add ${apAddr}/24 dev "$ap" || { teardown; die "could not address $ap"; }

        hw=g; extra=""
        if [ "$band" = a ]; then hw=a; extra="ieee80211ac=1"; fi
        ssid_esc=$(printf '%s' "$ssid" | ${pkgs.gnused}/bin/sed 's/[\\"]/\\&/g')
        umask 077
        {
          echo "interface=$ap"
          echo "driver=nl80211"
          echo "ctrl_interface=$run/hostapd"
          echo "ssid2=P\"$ssid_esc\""
          echo "utf8_ssid=1"
          echo "hw_mode=$hw"
          echo "channel=$chan"
          echo "ieee80211n=1"
          [ -n "$extra" ] && echo "$extra"
          echo "wmm_enabled=1"
          echo "auth_algs=1"
          echo "wpa=2"
          echo "wpa_key_mgmt=WPA-PSK"
          echo "rsn_pairwise=CCMP"
          echo "wpa_passphrase=$psk"
        } > "$run/hostapd.conf"
        umask 022

        # A dozing station radio adds latency for every client; the beacons
        # keep it awake regardless, so the saving is gone anyway.
        $iw dev "$sta" set power_save off 2>/dev/null || true

        $systemd_run --quiet --collect --unit=hotspot-hostapd \
          --property=KillMode=mixed \
          ${pkgs.hostapd}/bin/hostapd "$run/hostapd.conf" \
          || { teardown; die "could not start hostapd"; }

        # hostapd reports success asynchronously; the interface shows
        # `type AP` plus a channel line once it is actually beaconing.
        ok=0
        for _ in $(${pkgs.coreutils}/bin/seq 1 40); do
          if ! $systemctl is-active --quiet hotspot-hostapd.service; then break; fi
          if $iw dev "$ap" info 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q '^\s*channel'; then ok=1; break; fi
          ${pkgs.coreutils}/bin/sleep 0.25
        done
        if [ "$ok" != 1 ]; then
          reason=$($journalctl -u hotspot-hostapd.service -n 5 -o cat --no-pager 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -v '^$' | ${pkgs.coreutils}/bin/tail -n 2 | ${pkgs.coreutils}/bin/tr '\n' ' ')
          teardown
          die "hostapd did not come up on channel $chan: ''${reason:-no output}"
        fi

        # DHCP + DNS for clients. Forwards to resolved's stub only.
        : > "$run/leases"; chown nobody:nogroup "$run/leases"
        $systemd_run --quiet --collect --unit=hotspot-dnsmasq \
          ${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/dev/null \
            --no-hosts --no-resolv --server=127.0.0.53 \
            --bind-interfaces --interface="$ap" --except-interface=lo \
            --listen-address=${apAddr} \
            --dhcp-range=10.42.0.10,10.42.0.254,12h --dhcp-authoritative \
            --dhcp-option=option:router,${apAddr} \
            --dhcp-option=option:dns-server,${apAddr} \
            --dhcp-leasefile="$run/leases" \
          || { teardown; die "could not start dnsmasq"; }

        # NAT, forwarding, and the DNS catch-all for clients. Its own table so
        # it coexists with the iptables-nft firewall and libvirt untouched.
        ${pkgs.procps}/bin/sysctl -q -w net.ipv4.ip_forward=1
        $nft -f - <<EOF || { teardown; die "could not install nft rules"; }
    table inet hotspot {
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "$ap" ip daddr != ${apAddr} meta l4proto { tcp, udp } th dport 53 dnat ip to ${apAddr}
      }
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr ${apNet} ip daddr != ${apNet} oifname != "$ap" masquerade
      }
      chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "$ap" accept
        oifname "$ap" ct state related,established accept
      }
    }
    EOF
        echo "hotspot-guard: $ap up on $band/$chan"
        ;;
      down)
        teardown
        ;;
      *)
        echo "usage: hotspot-guard up <station-iface> <a|bg> <channel> | down <station-iface>" >&2
        exit 2
        ;;
    esac
  '';

  # ── hotspot: the user-facing switch. This is what the caelestia Network page
  # drives (services/Hotspot.qml); it also works from a terminal.
  hotspot = pkgs.writeShellScriptBin "hotspot" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.gnused ]}:$PATH
    nmcli=${pkgs.networkmanager}/bin/nmcli
    iw=${pkgs.iw}/bin/iw
    systemctl=${pkgs.systemd}/bin/systemctl
    guard="/run/wrappers/bin/sudo -n ${hotspot-guard}/bin/hotspot-guard"
    ap=${apIface}

    state="''${XDG_RUNTIME_DIR:-/tmp}/hotspot"
    mkdir -p "$state"
    errfile="$state/error"
    pinfile="$state/pinned-profile"

    cfgdir="''${XDG_CONFIG_HOME:-$HOME/.config}/hotspot"
    cfgfile="$cfgdir/config"

    fail() {
      echo "$*" > "$errfile"
      echo "hotspot: $*" >&2
    }

    # First run only: name after the machine, random WPA2 passphrase. Both
    # are edited afterwards from the settings page (`hotspot set ...`).
    ensure_config() {
      [ -f "$cfgfile" ] && return 0
      mkdir -p "$cfgdir"; chmod 700 "$cfgdir"
      psk=$(${pkgs.coreutils}/bin/tr -dc 'A-Za-z0-9' < /dev/urandom | ${pkgs.coreutils}/bin/head -c 12)
      (umask 077; printf 'ssid=%s\npsk=%s\n' "${config.networking.hostName}" "$psk" > "$cfgfile")
    }

    cfg_get() { ${pkgs.gawk}/bin/awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$cfgfile" 2>/dev/null; }

    cfg_set() {
      ensure_config
      tmp=$(${pkgs.coreutils}/bin/mktemp "$cfgdir/.config.XXXXXX")
      { ${pkgs.gnugrep}/bin/grep -v "^$1=" "$cfgfile" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$tmp"
      chmod 600 "$tmp"; mv "$tmp" "$cfgfile"
    }

    # The station interface: the wifi device that is not our AP.
    sta_iface() {
      $nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F: -v ap="$ap" '$2 == "wifi" && $1 != ap { print $1; exit }'
    }

    # "<channel> <freq>" of an interface's current link, or nothing.
    if_channel() {
      $iw dev "$1" info 2>/dev/null \
        | ${pkgs.gawk}/bin/awk '/^\tchannel/ { sub(/\(/, "", $3); print $2, $3; exit }'
    }

    sta_profile() {
      $nmcli -t -f DEVICE,CONNECTION device status 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F: -v d="$1" '$1 == d { print $2; exit }'
    }

    is_on() {
      $systemctl is-active --quiet hotspot-hostapd.service \
        && $iw dev "$ap" info 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q '^\s*type AP'
    }

    unpin() {
      [ -f "$pinfile" ] || return 0
      prof=$(cat "$pinfile")
      [ -n "$prof" ] && $nmcli connection modify "$prof" 802-11-wireless.band "" 2>/dev/null
      rm -f "$pinfile"
    }

    # Match the station's channel; with no station any 2.4 GHz channel is
    # fine and 6 is as good as any.
    guard_up() {
      dev=$1
      set -- $(if_channel "$dev")
      band=bg; chan=6
      if [ -n "''${1-}" ]; then
        chan=$1; [ "$2" -ge 5000 ] && band=a
      fi
      printf '%s\n%s\n' "$(cfg_get ssid)" "$(cfg_get psk)" | $guard up "$dev" "$band" "$chan" 2>&1
    }

    cmd_on() {
      rm -f "$errfile"
      [ "$($nmcli -t -f WIFI general 2>/dev/null)" = enabled ] || { fail "Wi-Fi is turned off"; return 1; }
      sta=$(sta_iface)
      [ -n "$sta" ] || { fail "no Wi-Fi interface found"; return 1; }
      ensure_config

      out=$(guard_up "$sta") && { echo "hotspot: on"; return 0; }

      # Most likely a channel the card may not beacon on (5 GHz DFS). Move the
      # station to 2.4 GHz and retry once — only when there *is* a station on
      # 5 GHz; otherwise the failure is something else and we report it.
      set -- $(if_channel "$sta")
      prof=$(sta_profile "$sta")
      if [ -n "''${2-}" ] && [ "$2" -ge 5000 ] && [ -n "$prof" ]; then
        echo "hotspot: AP refused on channel $1, moving '$prof' to 2.4 GHz" >&2
        $nmcli connection modify "$prof" 802-11-wireless.band bg \
          && echo "$prof" > "$pinfile" \
          && $nmcli -w 40 connection up "$prof" >/dev/null 2>&1
        out=$(guard_up "$sta") && { echo "hotspot: on (Wi-Fi moved to 2.4 GHz)"; return 0; }
      fi

      fail "$(echo "$out" | ${pkgs.gnugrep}/bin/grep -v '^$' | ${pkgs.coreutils}/bin/tail -n1 | ${pkgs.gnused}/bin/sed 's/^hotspot-guard: //')"
      unpin
      return 1
    }

    cmd_off() {
      $guard down "$(sta_iface)" || fail "could not tear down $ap (needs sudo)"
      unpin
      rm -f "$errfile"
      echo "hotspot: off"
    }

    # key=value lines; services/Hotspot.qml parses these.
    cmd_status() {
      ensure_config
      if is_on; then echo "state=on"; else echo "state=off"; fi
      echo "ssid=$(cfg_get ssid)"
      echo "psk=$(cfg_get psk)"
      if is_on; then
        set -- $(if_channel "$ap")
        if [ -n "''${1-}" ]; then
          echo "channel=$1"
          if [ "$2" -ge 5000 ]; then echo "band=a"; else echo "band=bg"; fi
        fi
        echo "address=${apAddr}"
        echo "clients=$($iw dev "$ap" station dump 2>/dev/null | ${pkgs.gnugrep}/bin/grep -c '^Station')"
      fi
      sta=$(sta_iface)
      if [ -n "$sta" ]; then
        echo "sta=$sta"
        set -- $(if_channel "$sta")
        [ -n "''${1-}" ] && echo "sta_channel=$1" && echo "sta_freq=$2"
        echo "sta_profile=$(sta_profile "$sta")"
      fi
      [ -f "$pinfile" ] && echo "pinned=$(cat "$pinfile")"
      [ -f "$errfile" ] && echo "error=$(cat "$errfile")"
      return 0
    }

    # hotspot set ssid <name> | set password <passphrase>. hostapd reads its
    # config once, so a running hotspot is bounced to pick the change up.
    cmd_set() {
      v="''${2-}"
      n=$(printf '%s' "$v" | ${pkgs.coreutils}/bin/wc -c)
      case "''${1-}" in
        ssid)
          [ "$n" -ge 1 ] && [ "$n" -le 32 ] && [[ "$v" != *[[:cntrl:]]* ]] \
            || { echo "hotspot: SSID must be 1–32 bytes" >&2; return 2; }
          cfg_set ssid "$v"
          ;;
        password)
          [[ "$v" =~ ^[[:print:]]{8,63}$ ]] \
            || { echo "hotspot: password must be 8–63 printable ASCII characters" >&2; return 2; }
          cfg_set psk "$v"
          ;;
        *)
          echo "usage: hotspot set ssid <name> | set password <passphrase>" >&2
          return 2
          ;;
      esac
      if is_on; then cmd_on; fi
    }

    case "''${1-toggle}" in
      on|up)      cmd_on ;;
      off|down)   cmd_off ;;
      toggle)     if is_on; then cmd_off; else cmd_on; fi ;;
      status)     cmd_status ;;
      set)        shift; cmd_set "$@" ;;
      *)
        echo "usage: hotspot [on|off|toggle|status|set ssid <name>|set password <pass>]" >&2
        exit 2
        ;;
    esac
  '';
in
{
  environment.systemPackages = [ hotspot hotspot-guard pkgs.iw ];

  security.sudo.extraRules = [
    {
      groups = [ "wheel" ];
      commands = [
        {
          command = "${hotspot-guard}/bin/hotspot-guard";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # See the header: NM must never take ap0, or it resets it to station mode.
  networking.networkmanager.unmanaged = [ "interface-name:${apIface}" ];

  # dnsmasq's DHCP and DNS on ap0. Only what clients need; nothing else on
  # the host is exposed to hotspot clients.
  networking.firewall.interfaces.${apIface} = {
    allowedUDPPorts = [ 53 67 ];
    allowedTCPPorts = [ 53 ];
  };

  # ── wpa_supplicant as upstream ships it (see header).
  networking.wireless.enable = lib.mkForce false;
  services.dbus.packages = [ pkgs.wpa_supplicant ];
  systemd.services.wpa_supplicant = {
    description = "WPA supplicant";
    wantedBy = [ "multi-user.target" ];
    after = [ "dbus.service" ];
    aliases = [ "dbus-fi.w1.wpa_supplicant1.service" ];
    serviceConfig = {
      Type = "dbus";
      BusName = "fi.w1.wpa_supplicant1";
      ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -u -s -O /run/wpa_supplicant";
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
    };
  };
}
