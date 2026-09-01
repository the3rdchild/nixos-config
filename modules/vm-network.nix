{ ... }:
{
  # ── The PLC-side network for the CX-One guest (./libvirt.nix).
  #
  # Deliberately a separate module rather than an edit to ./network.nix. That
  # file is the host's own connectivity — NetworkManager, the WireGuard
  # full-tunnel, WARP, the DNS-leak guard — and none of it has anything to do
  # with handing a guest a wire. Keeping them apart means a mistake here cannot
  # take the laptop off the network.
  #
  # Shape of the thing: the guest gets TWO NICs.
  #
  #   virbr0  (libvirt's default NAT)  -> internet, for Windows updates and
  #                                       the CX-One installer's activation
  #   br-plc  (this module)            -> the physical enp4s0 port, i.e. the
  #                                       cable to the controller
  #
  # enp4s0 is free: the host lives on wifi (wlp5s0), and the ethernet port has
  # been down with no carrier. Dedicating it to the PLC costs nothing and means
  # FINS/EtherNet-IP goes out a real wire at layer 2, with the guest holding a
  # static address on the controller's subnet the way CX-Programmer expects
  # (an NJ/CJ2 Ethernet port ships on 192.168.250.1; the PC side is normally
  # 192.168.250.x/24, set inside Windows, not here).

  # A bridge rather than macvtap/"direct attachment". macvtap would need no
  # host configuration at all and is the tempting answer, but it only exists
  # while its lower device does, and this cable gets plugged and unplugged
  # constantly. br-plc is present whether or not anything is in the port, so
  # the guest can boot, and stay booted, across a cable swap. The macvtap
  # host<->guest isolation caveat is irrelevant here either way — the host is
  # not the thing talking to the PLC.
  networking.bridges."br-plc".interfaces = [ "enp4s0" ];

  # No host address on the bridge. The guest does the talking, and a second
  # default route on this box is a known problem — see the rpfilter section of
  # ./network.nix for the three hours that cost once already.
  #
  # To *also* reach the PLC from Linux (python-fins, libplctag, the OpenPLC
  # work in ./openplc.nix), give the host a static address on the controller's
  # subnet instead of DHCP — still no default route, so nothing is disturbed:
  #     networking.interfaces."br-plc".ipv4.addresses = [
  #       { address = "192.168.250.11"; prefixLength = 24; }
  #     ];
  networking.interfaces."br-plc".useDHCP = false;

  # NetworkManager owns every interface it is not told to leave alone, and it
  # will happily fight the scripted bridge setup over both of these — enslaving
  # enp4s0 races NM's own autoconnect, and NM would otherwise try to DHCP the
  # bridge. Both must be listed; naming only the bridge is the usual way to get
  # an enp4s0 that keeps dropping out of it.
  #
  # CONSEQUENCE: enp4s0 is no longer a normal plug-and-go ethernet port. An
  # internet cable in it will not bring the host online any more. If that is
  # ever wanted back, set useDHCP = true on br-plc above (the host then routes
  # through the bridge) rather than removing it from NM's unmanaged list.
  networking.networkmanager.unmanaged = [
    "interface-name:enp4s0"
    "interface-name:br-plc"
  ];

  # ── Firewall: two things that would otherwise eat the PLC traffic silently.
  #
  # 1. br_netfilter is loaded on this system and net.bridge.bridge-nf-call-
  #    iptables is 1, so *bridged* frames are pushed through iptables FORWARD
  #    instead of being switched transparently. That is normally harmless,
  #    because networking.firewall.filterForward is false here and the FORWARD
  #    policy stays ACCEPT.
  #
  # 2. ...until Docker starts. ./docker.nix keeps the daemon masked at boot but
  #    explicitly expects `sudo systemctl start docker` on demand, and the
  #    first thing dockerd does is `iptables -P FORWARD DROP`. Combined with
  #    (1), starting Docker would kill every packet between the guest and the
  #    controller, with no log line and nothing changed on either end. The
  #    symptom would be CX-Programmer timing out on a link that worked an hour
  #    ago — and the cause would be a container.
  #
  # Two explicit ACCEPTs pin the bridge open regardless of what the policy
  # becomes. -C before -I so a firewall reload does not stack duplicates.
  networking.firewall.trustedInterfaces = [ "br-plc" ];

  networking.firewall.extraCommands = ''
    for dir in i o; do
      iptables -w -C FORWARD -$dir br-plc -j ACCEPT 2>/dev/null \
        || iptables -w -I FORWARD -$dir br-plc -j ACCEPT
    done
  '';

  networking.firewall.extraStopCommands = ''
    for dir in i o; do
      iptables -w -D FORWARD -$dir br-plc -j ACCEPT 2>/dev/null || true
    done
  '';

  # NOTE on guest DNS over the NAT NIC: libvirt runs a dnsmasq on virbr0, which
  # forwards upstream using /etc/resolv.conf — 127.0.0.53, systemd-resolved's
  # stub. The dns-leak-guard in ./network.nix REJECTs outbound port 53, but it
  # RETURNs early for 127.0.0.0/8, so that path is already allowed and the
  # guest resolves normally. If resolved is ever removed and resolv.conf comes
  # to hold a real upstream address, the guard will start rejecting libvirt's
  # forwards and the VM will look like it has no DNS while the host is fine.
}
