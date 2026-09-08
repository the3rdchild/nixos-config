{ ... }:
{
  # ── The PLC-side network for the CX-One guest (./libvirt.nix).
  #
  # This module currently configures NOTHING. That is the design, not neglect:
  # enp4s0 is a plain ethernet port again, managed by NetworkManager the
  # ordinary plug-and-go way, and the guest's wire to the controller will come
  # from a USB-C ethernet adapter passed straight through to the VM instead.
  # The reasoning, and the three failures that produced it, are below — they
  # cost enough to be worth keeping.
  #
  # Deliberately still a separate module rather than an edit to ./network.nix.
  # That file is the host's own connectivity — NetworkManager, the WireGuard
  # full-tunnel, WARP, the DNS-leak guard — and none of it has anything to do
  # with handing a guest a wire. Keeping them apart means a mistake here cannot
  # take the laptop off the network.

  # ── What this used to be, and why it is gone.
  #
  # The original shape: enp4s0 enslaved to a bridge br-plc, both interfaces in
  # networkmanager.unmanaged, no host address anywhere, the guest holding a
  # static address on the controller's subnet. Correct for the PLC, and it
  # quietly cost the host its only gigabit port — enp4s0 negotiated 1000Mb/s
  # full duplex with link detected while neither it nor br-plc had any IPv4, so
  # every packet went out the wifi and the wire looked broken in the one way
  # ethtool cannot show you.
  #
  # Three attempts to have one NIC serve both, in order, and how each died:
  #
  # 1. Keep the scripted bridge, just take br-plc off the unmanaged list so NM
  #    supplies an address on a device someone else built.
  #
  #      Sep 08 11:32:24 kernel: r8169 enp4s0: left promiscuous mode
  #      Sep 08 11:32:24 kernel: br-plc: port 1(enp4s0) entered disabled state
  #
  #    The moment NM stopped treating br-plc as unmanaged it enforced the port
  #    list from its own profile — which named none — and released enp4s0. The
  #    bridge went empty, then down; and a software device NM did not create,
  #    sitting down with no config, is one NM flags unmanaged again, so the
  #    profile never activated. A controller cannot have two owners.
  #
  # 2. Give NM both halves: a bridge profile plus a bridge-port profile for
  #    enp4s0, no scripted bridge at all.
  #
  #      enp4s0:ethernet:connected:Wired connection 1
  #      br-plc:bridge:connecting (getting IP configuration):br-plc
  #
  #    NM generates a "Wired connection 1" for any managed ethernet with no
  #    profile it considers activatable *on its own*, and a port profile does
  #    not count — it cannot stand alone. So NM decided enp4s0 was profile-less,
  #    invented one, and connected it first. The host got an address on the
  #    wrong interface and the bridge came up with no port. autoconnect-priority
  #    does not help: the two are never weighed against each other, because the
  #    generated one is created only after NM concluded there was nothing to
  #    weigh. `[main] no-auto-default` is the real answer to that part.
  #
  # 3. Same, plus no-auto-default, plus ipv6.method = link-local so a DHCP
  #    failure on a PLC (which runs no DHCP server) could not tear the bridge
  #    out from under a running guest.
  #
  #      NetworkManager-wait-online.service: Failed with result 'exit-code'
  #
  #    Two things learned here. First, may-fail and link-local do not make
  #    activation immediate: may-fail governs whether a family's *failure*
  #    kills the connection, but NM still waits for every configured family to
  #    finish before calling the device activated. An ipv4.dhcp-timeout of
  #    "infinity" therefore hangs the device forever, NM never reports startup
  #    complete, `nm-online -s` times out, and the rebuild exits 4.
  #
  #    Second, and fatal to the whole approach: a bridge with no ports has
  #    carrier 0, and DHCP never *starts* without carrier — so the 45s timeout
  #    is never even counted. An empty br-plc hangs in "getting IP
  #    configuration" indefinitely and fails wait-online on every boot. The
  #    port is the host's uplink exactly when it is not the guest's wire, so
  #    "empty" is a normal state, not an edge case.
  #
  # The common cause under all three is one physical NIC asked to be the host's
  # uplink and the guest's fieldbus at the same time. A second NIC removes it.

  # ── Where this is going: USB-C ethernet, passed through to the guest.
  #
  # When the adapter arrives, the PLC wire becomes a USB device handed directly
  # to the VM with a libvirt <hostdev>, pinned by USB vendor:product. Windows
  # drives the NIC; the host never touches it.
  #
  # Why passthrough and not a second bridge on the adapter — a bridge would
  # work, but it buys back every problem above on a different interface:
  #
  #   * No host network configuration at all. No bridge, no unmanaged list, no
  #     NM profiles, no no-auto-default, no network-addresses-* units.
  #   * Nothing waits on carrier, so nothing can hang wait-online.
  #   * Layer 2 is native. FINS/EtherNet-IP never crosses a bridge, so it never
  #     crosses br_netfilter or the FORWARD chain — which retires a real trap
  #     this module used to carry: ./docker.nix expects `systemctl start
  #     docker` on demand, and the first thing dockerd does is `iptables -P
  #     FORWARD DROP`. With bridge-nf-call-iptables at 1, starting a container
  #     would have killed every packet between guest and controller, with no
  #     log line and nothing changed on either end. CX-Programmer would time
  #     out on a link that worked an hour ago, and the cause would be Docker.
  #   * Unplugging is clean: the device leaves the guest, and no orphan bridge
  #     is left behind attracting traffic.
  #
  # Buying notes: Realtek RTL8153 or ASIX AX88179. The driver that has to exist
  # is the *guest's*, not the host's, and Windows has both. USB 3.0 for
  # gigabit, though PLC traffic could not care less.
  #
  # What this gives up: the host cannot talk to the controller. python-fins,
  # libplctag, and the OpenPLC work in ./openplc.nix would all be inside the
  # guest only. If host-side access is ever wanted, bridge the USB NIC instead
  # of passing it through — the failure modes above are about sharing ONE port,
  # and do not apply to a NIC dedicated to the bridge.
  #
  # To wire it up: plug the adapter, read the ids from `lsusb`, and add to the
  # domain in ./libvirt.nix
  #
  #     <hostdev mode='subsystem' type='usb' managed='yes'>
  #       <source><vendor id='0x0bda'/><product id='0x8153'/></source>
  #     </hostdev>
  #
  # The guest keeps its existing virbr0 NIC for internet (Windows updates, the
  # CX-One installer's activation) and gets the controller on the passed-through
  # one, holding a static address on the controller's subnet the way
  # CX-Programmer expects — an NJ/CJ2 Ethernet port ships on 192.168.250.1, so
  # the PC side is normally 192.168.250.x/24, set inside Windows, not here.
}
