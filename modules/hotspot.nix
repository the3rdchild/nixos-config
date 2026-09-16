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
# channel. NetworkManager cannot put two connections on one device, though, so
# the AP needs its own virtual interface. `hotspot-guard up` creates it with
# `iw ... interface add ap0 type __ap`. The `__ap` type matters: when the
# interface is already in AP mode, wpa_supplicant treats it as a "static AP"
# and never flips it to station mode for scanning — which would trip the
# `managed <= 1` limit the moment it came up next to wlp5s0.
#
# The `#channels <= 1` rule is enforced by the kernel, not negotiated: an AP on
# a different channel from the station fails with EBUSY. `hotspot on` reads
# the station's channel and pins the Hotspot profile to it before activation.
# When that still fails — the station is on a DFS channel (52–144), where AP
# mode is never allowed on this card — it re-pins the Wi-Fi profile to 2.4 GHz,
# reconnects, and tries once more. The pin is undone by `hotspot off`.
#
# DHCP and DNS for clients come from NetworkManager's own dnsmasq (ipv4.method
# shared, 10.42.0.0/24). That dnsmasq reads /etc/resolv.conf, which is the
# systemd-resolved stub, so client lookups ride the same strict-DoT path as
# the host's — dns-leak-guard in ./network.nix never sees plaintext :53
# leaving the box, because the only :53 traffic is loopback. NAT is NM's own
# nftables table. Forwarded client traffic is unmarked, so when wg0 is up the
# policy rule sends it through the tunnel like everything else.
#
# What needs root is exactly the virtual interface (create/delete) and the
# power-save toggle on the station, so those live in hotspot-guard with a
# store-path-scoped NOPASSWD rule — the same shape as wg0-purge and
# portal-guard in ./network.nix. Everything nmcli is already passwordless for
# the networkmanager group via polkit.

let
  apIface = "ap0";
  conName = "Hotspot";
  # Fixed so NetworkManager.conf can name the one profile allowed on ap0
  # without depending on the (user-editable) profile name.
  conUuid = "7b1a3f2e-5c8d-4e1a-9f0b-2d6c4a8e1f30";

  # ── hotspot-guard: the root half. Creates/removes the AP interface and
  # toggles station power-save. Validates its own arguments.
  hotspot-guard = pkgs.writeShellScriptBin "hotspot-guard" ''
    set -u
    iw=${pkgs.iw}/bin/iw
    ap=${apIface}

    die() { echo "hotspot-guard: $*" >&2; exit 1; }

    sta="''${2-}"
    [[ "$sta" =~ ^[a-z0-9]+$ ]] || die "bad interface name"
    [ -d "/sys/class/net/$sta/wireless" ] || die "$sta is not a wireless interface"

    # Restore whatever ./power.nix asked NetworkManager for. NM re-applies it
    # on the next (re)activation anyway; this just closes the gap.
    powersave=${if config.networking.networkmanager.wifi.powersave then "on" else "off"}

    case "''${1-}" in
      up)
        # Always recreate. NM resets a wifi device to infrastructure mode when
        # it deactivates the AP profile, so a leftover ap0 is no longer a
        # static-AP interface and wpa_supplicant would try to scan on it.
        if [ -d "/sys/class/net/$ap" ]; then
          $iw dev "$ap" del || die "could not remove stale $ap"
        fi

        # Locally-administered MAC derived from the station's: set the
        # local bit, flip the low bit of the last octet so it never collides
        # with the station itself.
        IFS=: read -r o1 o2 o3 o4 o5 o6 < "/sys/class/net/$sta/address"
        o1=$(printf '%02x' $(( 0x$o1 | 0x02 )))
        o6=$(printf '%02x' $(( 0x$o6 ^ 0x01 )))
        $iw dev "$sta" interface add "$ap" type __ap addr "$o1:$o2:$o3:$o4:$o5:$o6" \
          || die "could not create $ap on $sta"

        # A dozing station radio adds latency for every client; the beacons
        # keep it awake regardless, so the saving is gone anyway.
        $iw dev "$sta" set power_save off 2>/dev/null || true
        ;;
      down)
        if [ -d "/sys/class/net/$ap" ]; then
          $iw dev "$ap" del || die "could not remove $ap"
        fi
        $iw dev "$sta" set power_save "$powersave" 2>/dev/null || true
        ;;
      *)
        echo "usage: hotspot-guard up|down <station-interface>" >&2
        exit 2
        ;;
    esac
  '';

  # ── hotspot: the user-facing switch. This is what the caelestia Network page
  # drives (services/Hotspot.qml); it also works from a terminal.
  hotspot = pkgs.writeShellScriptBin "hotspot" ''
    set -u
    nmcli=${pkgs.networkmanager}/bin/nmcli
    iw=${pkgs.iw}/bin/iw
    guard="/run/wrappers/bin/sudo -n ${hotspot-guard}/bin/hotspot-guard"
    ap=${apIface}
    con=${conName}
    uuid=${conUuid}

    state="''${XDG_RUNTIME_DIR:-/tmp}/hotspot"
    mkdir -p "$state"
    errfile="$state/error"
    pinfile="$state/pinned-profile"

    fail() {
      echo "$*" > "$errfile"
      echo "hotspot: $*" >&2
    }

    # The station interface: the wifi device that is not our AP.
    sta_iface() {
      $nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F: -v ap="$ap" '$2 == "wifi" && $1 != ap { print $1; exit }'
    }

    # "<channel> <freq>" of the station's current link, or nothing.
    sta_channel() {
      $iw dev "$1" info 2>/dev/null \
        | ${pkgs.gawk}/bin/awk '/^\tchannel/ { sub(/\(/, "", $3); print $2, $3; exit }'
    }

    sta_profile() {
      $nmcli -t -f DEVICE,CONNECTION device status 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F: -v d="$1" '$1 == d { print $2; exit }'
    }

    # NM needs a moment to register a freshly created interface; `connection
    # up` on a profile bound to a device NM has not seen yet fails with "no
    # suitable device". Wait for it to reach disconnected (= ready).
    wait_ap() {
      for _ in $(${pkgs.coreutils}/bin/seq 1 40); do
        st=$($nmcli -t -f DEVICE,STATE device status 2>/dev/null \
          | ${pkgs.gawk}/bin/awk -F: -v d="$ap" '$1 == d { print $2; exit }')
        case "$st" in disconnected|connected|connecting*) return 0 ;; esac
        ${pkgs.coreutils}/bin/sleep 0.25
      done
      return 1
    }

    con_state() {
      $nmcli -t -f NAME,STATE connection show --active 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F: -v c="$con" '$1 == c { print $2; exit }'
    }

    profile_exists() {
      $nmcli -t -f UUID connection show 2>/dev/null | ${pkgs.gnugrep}/bin/grep -qx "$uuid"
    }

    # First run only: name after the machine, random WPA2 passphrase. Both
    # are edited afterwards from the settings page (`hotspot set ...`) and
    # live in NetworkManager's profile store, not here.
    ensure_profile() {
      profile_exists && return 0
      psk=$(${pkgs.coreutils}/bin/tr -dc 'A-Za-z0-9' < /dev/urandom | ${pkgs.coreutils}/bin/head -c 12)
      $nmcli connection add type wifi ifname "$ap" con-name "$con" \
        connection.uuid "$uuid" autoconnect no \
        ssid "${config.networking.hostName}" \
        802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel 6 \
        802-11-wireless.powersave 2 \
        ipv4.method shared ipv6.method disabled \
        wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn \
        wifi-sec.pairwise ccmp wifi-sec.group ccmp \
        wifi-sec.psk "$psk" >/dev/null
    }

    # Match the station's channel; with no station, any 2.4 GHz channel is
    # fine and 6 is as good as any.
    apply_channel() {
      set -- $(sta_channel "$1")
      if [ -n "''${1-}" ]; then
        band=bg; [ "$2" -ge 5000 ] && band=a
        $nmcli connection modify "$con" 802-11-wireless.band "$band" 802-11-wireless.channel "$1"
      else
        $nmcli connection modify "$con" 802-11-wireless.band bg 802-11-wireless.channel 6
      fi
    }

    unpin() {
      [ -f "$pinfile" ] || return 0
      prof=$(cat "$pinfile")
      [ -n "$prof" ] && $nmcli connection modify "$prof" 802-11-wireless.band "" 2>/dev/null
      rm -f "$pinfile"
    }

    cmd_on() {
      rm -f "$errfile"
      [ "$($nmcli -t -f WIFI general 2>/dev/null)" = enabled ] || { fail "Wi-Fi is turned off"; return 1; }
      sta=$(sta_iface)
      [ -n "$sta" ] || { fail "no Wi-Fi interface found"; return 1; }
      [ "$(con_state)" = activated ] && { echo "hotspot: already on"; return 0; }

      ensure_profile || { fail "could not create the $con profile"; return 1; }
      $guard up "$sta" || { fail "could not create $ap (needs sudo)"; return 1; }
      # Belt and braces next to allowed-connections in NetworkManager.conf.
      $nmcli device set "$ap" autoconnect no >/dev/null 2>&1 || true
      wait_ap || { fail "NetworkManager did not pick up $ap"; $guard down "$sta" >/dev/null 2>&1; return 1; }

      apply_channel "$sta"
      out=$($nmcli -w 40 connection up "$con" 2>&1) && { echo "hotspot: on"; return 0; }

      # Most likely a channel the card may not beacon on (5 GHz DFS). Move the
      # station to 2.4 GHz and retry once. Only when there *is* a station on
      # 5 GHz; otherwise the failure is something else and we report it.
      set -- $(sta_channel "$sta")
      prof=$(sta_profile "$sta")
      if [ -n "''${2-}" ] && [ "$2" -ge 5000 ] && [ -n "$prof" ]; then
        echo "hotspot: AP refused on channel $1, moving '$prof' to 2.4 GHz" >&2
        $nmcli connection modify "$prof" 802-11-wireless.band bg \
          && echo "$prof" > "$pinfile" \
          && $nmcli -w 40 connection up "$prof" >/dev/null 2>&1
        apply_channel "$sta"
        out=$($nmcli -w 40 connection up "$con" 2>&1) && { echo "hotspot: on (Wi-Fi moved to 2.4 GHz)"; return 0; }
      fi

      fail "$(echo "$out" | ${pkgs.coreutils}/bin/tail -n1)"
      $nmcli connection down "$con" >/dev/null 2>&1 || true
      $guard down "$sta" >/dev/null 2>&1 || true
      unpin
      return 1
    }

    cmd_off() {
      sta=$(sta_iface)
      $nmcli connection down "$con" >/dev/null 2>&1 || true
      [ -n "$sta" ] && { $guard down "$sta" || fail "could not remove $ap (needs sudo)"; }
      unpin
      rm -f "$errfile"
      echo "hotspot: off"
    }

    # key=value lines; services/Hotspot.qml parses these.
    cmd_status() {
      st=$(con_state)
      case "$st" in
        activated) echo "state=on" ;;
        activating) echo "state=starting" ;;
        deactivating) echo "state=stopping" ;;
        *) echo "state=off" ;;
      esac
      if profile_exists; then
        echo "ssid=$($nmcli -g 802-11-wireless.ssid connection show "$con" 2>/dev/null)"
        echo "psk=$($nmcli -s -g 802-11-wireless-security.psk connection show "$con" 2>/dev/null)"
        echo "band=$($nmcli -g 802-11-wireless.band connection show "$con" 2>/dev/null)"
        echo "channel=$($nmcli -g 802-11-wireless.channel connection show "$con" 2>/dev/null)"
      fi
      if [ "$st" = activated ]; then
        echo "address=$($nmcli -g IP4.ADDRESS connection show "$con" 2>/dev/null | ${pkgs.coreutils}/bin/cut -d/ -f1)"
        echo "clients=$($iw dev "$ap" station dump 2>/dev/null | ${pkgs.gnugrep}/bin/grep -c '^Station')"
      fi
      sta=$(sta_iface)
      if [ -n "$sta" ]; then
        echo "sta=$sta"
        set -- $(sta_channel "$sta")
        [ -n "''${1-}" ] && echo "sta_channel=$1" && echo "sta_freq=$2"
        echo "sta_profile=$(sta_profile "$sta")"
      fi
      [ -f "$pinfile" ] && echo "pinned=$(cat "$pinfile")"
      [ -f "$errfile" ] && echo "error=$(cat "$errfile")"
      return 0
    }

    # hotspot set ssid <name> | set password <passphrase>. Applied live if the
    # hotspot is up: NM does not push SSID/PSK changes into a running AP, so
    # it is bounced.
    cmd_set() {
      ensure_profile || { fail "could not create the $con profile"; return 1; }
      case "''${1-}" in
        ssid)
          v="''${2-}"
          n=$(printf '%s' "$v" | ${pkgs.coreutils}/bin/wc -c)
          [ "$n" -ge 1 ] && [ "$n" -le 32 ] || { echo "hotspot: SSID must be 1–32 bytes" >&2; return 2; }
          $nmcli connection modify "$con" 802-11-wireless.ssid "$v" || return 1
          ;;
        password)
          v="''${2-}"
          n=$(printf '%s' "$v" | ${pkgs.coreutils}/bin/wc -c)
          [ "$n" -ge 8 ] && [ "$n" -le 63 ] || { echo "hotspot: password must be 8–63 characters" >&2; return 2; }
          $nmcli connection modify "$con" wifi-sec.psk "$v" || return 1
          ;;
        *)
          echo "usage: hotspot set ssid <name> | set password <passphrase>" >&2
          return 2
          ;;
      esac
      if [ "$(con_state)" = activated ]; then
        $nmcli -w 40 connection up "$con" >/dev/null 2>&1 || { fail "could not restart the hotspot"; return 1; }
      fi
    }

    case "''${1-toggle}" in
      on|up)      cmd_on ;;
      off|down)   cmd_off ;;
      toggle)     if [ "$(con_state)" = activated ]; then cmd_off; else cmd_on; fi ;;
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

  # ap0 exists only while the hotspot is up, but NM would still treat it as a
  # second station the moment it appears: scan on it and try to autoconnect
  # any saved Wi-Fi profile there. Only the Hotspot profile may ever activate
  # on it, and there is nothing to gain from a random MAC on an AP.
  networking.networkmanager.settings."device-hotspot" = {
    match-device = "interface-name:${apIface}";
    allowed-connections = "uuid:${conUuid}";
    "wifi.scan-rand-mac-address" = "no";
  };

  # NM's own nftables table accepts DHCP/DNS from clients, but under nft an
  # accept in one table does not short-circuit the NixOS firewall's input
  # chain in another, so it has to be opened here too. Only what the shared
  # dnsmasq serves; nothing else on the host is exposed to hotspot clients.
  networking.firewall.interfaces.${apIface} = {
    allowedUDPPorts = [ 53 67 ];
    allowedTCPPorts = [ 53 ];
  };
}
