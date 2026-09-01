# CX-One in a VM

Omron CX-One V4.60 is Windows-only. This is the KVM guest that replaces
booting the dual-boot Windows partition just to talk to a PLC.

Declared in [`modules/libvirt.nix`](../modules/libvirt.nix) (hypervisor, TPM,
USB redirection) and [`modules/vm-network.nix`](../modules/vm-network.nix)
(the `br-plc` bridge over `enp4s0`). Both are read before this document is —
the *why* lives in the comments there, the *how* lives here.

---

## TL;DR

```fish
sudo nixos-rebuild switch --flake /mnt/doc/config#noouoops
# log out and back in once, for the libvirtd group
sudo bash docs/cxone-vm-create.sh --dry-run   # validate first
sudo bash docs/cxone-vm-create.sh             # defines the guest
virt-manager                          # console, USB redirection
```

---

## Layout

| Thing | Where | Why there |
|---|---|---|
| Guest disk | `/var/lib/libvirt/images/cxone.qcow2` | ext4 root. ~106 GB free; 80 GB sparse image. |
| Install media | `/mnt/shared/VM/iso/` | Internal NVMe, `umask=0022` so mode 0644 — qemu can read it. |
| Windows | `Win11-25H2-GhostSpectre-WPE.iso` | Debloated 25H2. Idles ~2-2.5 GB instead of ~4. |
| CX-One | `CX-One_V4.60.iso` | Built from the DVD tree with `xorriso`; `Key_Install.txt` is at the ISO root. |

The Windows image was checked before use, because "WPE Edition" in the file
name suggests a custom WinPE imaging tool rather than an installer. It is not:
the ISO is UDF with `sources/install.wim` (4.86 GB), `sources/boot.wim`,
`efi/boot/bootx64.efi` and no `autounattend.xml` — an ordinary, interactive,
UEFI-bootable Windows Setup. The steps below are the normal ones.
| virtio drivers | `/etc/virtio-win.iso` | Built in `modules/libvirt.nix`. nixpkgs' `virtio-win` is the *extracted* tree with no ISO in it, so the module packs one. |

**The media had to be copied off `/run/media`.** That path is
`drwxr-x--- root:root` with a udisks ACL for `noouoops` only, so the
`qemu-libvirtd` user cannot traverse it — pointing a domain at an ISO on the
removable Programs disk fails with a bare `Permission denied` that reads like
a libvirt bug and is not one.

---

## 1. Rebuild

```fish
sudo nixos-rebuild switch --flake /mnt/doc/config#noouoops
```

Then **log out and back in**, or the `libvirtd` group membership will not be
in your session and virt-manager will only offer `qemu:///session`.

Check:

```fish
systemctl status libvirtd.socket    # socket-activated, not running yet: fine
ip link show br-plc                 # must exist even with no cable in enp4s0
groups | string match -q '*libvirtd*'; and echo ok
```

## 2. Create the guest

`docs/cxone-vm-create.sh` in this repo. Run it once. It is a plain
`virt-install` invocation, kept as a file so the domain is reproducible rather
than a sequence of clicks nobody wrote down.

Choices baked in, and why:

- **4 GiB / 4 vCPU.** The host has 15.3 GiB and already runs under memory
  pressure — see the diagnosis in [`modules/memory.nix`](../modules/memory.nix).
  Close Zen and VS Code while the VM is up. virtio-balloon is enabled so the
  guest hands RAM back when idle (needs the guest tools from step 4).
- **virtio disk, e1000e NICs.** virtio is a real win on CX-One's many small
  writes and is worth the one-time driver load in step 3. The NICs are emulated
  Intel deliberately: FINS is tiny packets so there is nothing to gain from
  virtio there, and a well-emulated real NIC is the boring choice for L2
  protocols on the PLC wire.
- **Two NICs.** `default` (NAT, virbr0) for internet, `br-plc` for the
  controller.
- **UEFI + emulated TPM 2.0.** Not strictly needed by a debloated image, but
  costs nothing and means the same domain works if you ever reinstall from the
  official ISO.
- **Two `spicevmc` redirect slots** for hot-plugging the PLC cable.

## 3. Install Windows

Boot the guest. When setup asks *where* to install and shows **no drives**,
that is expected — the virtio disk needs its driver:

1. **Load driver** → **Browse**
2. the virtio CD → `amd64\w11\` → OK
3. pick *Red Hat VirtIO SCSI controller*, Next

The 80 GB disk appears. Continue normally.

> If this goes wrong, the escape hatch is to change the disk bus to SATA in
> virt-manager and reinstall — no driver needed, slightly slower, entirely
> adequate for this workload.

## 4. Guest tools

**Do not run `virtio-win-guest-tools.exe`.** On this debloated image it fails
with `0x80070643` and rolls the whole bundle back. The log shows why: the
driver package installs fine —

    Applied rollback package: virtio_win_gt_x64.msi, result: 0x0

— and is then *undone* because a later, optional sub-package (the QEMU guest
agent) fails against a component GhostSpectre stripped. The bundle is
all-or-nothing, so one optional piece takes the drivers with it.

Run the driver MSI on its own instead:

    E:\virtio-win-gt-x64.msi

If even that fails, the balloon is the only part worth chasing by hand:
Device Manager → the unknown `PCI Device` → Update driver → Browse →
`E:\Balloon\w11\amd64`, then from an admin prompt

    E:\Balloon\w11\amd64\blnsvr.exe -i

(`Error 1073 — service already exists` means it is installed already, which is
success, not failure.)

Two things this ISO will never give you, whatever you run:

- **No SPICE vdagent.** nixpkgs' `virtio-win` ships no SPICE tools at all, so
  there is no host/guest clipboard and no auto-resize. Those need
  `spice-guest-tools` from spice-space.org, downloaded inside the guest.
- **No QEMU guest agent**, unless `E:\guest-agent\qemu-ga-x86_64.msi`
  installs standalone. It only buys graceful shutdown from `virsh`; nothing
  here depends on it.

### The balloon does not reclaim by itself

This is the part that is easy to get wrong. Installing the balloon driver does
not make the guest hand memory back — virtio-balloon is *host-driven*. The
driver means the host **can** reclaim; nothing pulls the lever for you. With a
4 GiB guest idling at ~2 GiB used, the host still backs all 4 GiB in RSS until
told otherwise.

First enable stats collection (off by default, which is why `dommemstat` shows
only `actual`/`rss` on a fresh domain):

```fish
virsh -c qemu:///system dommemstat cxone --period 5 --live --config
```

Then `unused`, `available` and `usable` appear, and the lever is:

```fish
virsh -c qemu:///system setmem cxone 2560M --live   # shrink
virsh -c qemu:///system setmem cxone 4G --live      # restore
```

Leave it at full size during the CX-One install — that is the most
allocation-heavy thing this guest will ever do. Shrink afterwards, when it is
sitting idle with a project open.

## 5. Install CX-One

The third CD-ROM is `CX-One_V4.60.iso`. Run `setup.exe` from it. The licence
key is in `Key_Install.txt` at the root of the same CD.

Two things worth knowing, both checked against the media rather than assumed:

- **The install needs no internet.** Every prerequisite is bundled in
  `ISSetupPrerequisites/`: .NET Framework 4.0 Full, .NET 4.6.1, WIC x86/x64,
  and a set of MSI updates for XP/Server 2003 that will not apply to a modern
  OS anyway. Windows 11 already satisfies the .NET entries. Nothing is fetched
  from Omron.
- **There is no OS version block.** `Setup.ini` carries `SuppressWrongOS=Y`, so
  the V4.60 installer will not refuse Windows 11 for being newer than anything
  it knows about — 4.60 is a 2020 release whose newest supported OS is
  Windows 10.

The language dialog defaults to English (`setuplang.ini` → `default=1033`),
despite `Setup.ini` naming Japanese as its own default; `setuplang.ini` is the
one `setup.exe` reads.

Install only what is needed — the full suite is ~8 GB and most of it is for
hardware you do not have. CX-Programmer, CX-Designer, CX-Integrator and
CX-Server cover the usual work.

## 6. Connect to the PLC

### USB-serial (the usual case)

With the guest running, plug the cable in, then in virt-manager:
**Virtual Machine → Redirect USB device →** tick the cable.

Identify it on the host first if it is not obvious:

```fish
lsusb            # before and after plugging in; the new line is the cable
```

Windows then wants the vendor driver — Omron's USB-serial driver ships with
CX-One and installs during step 5, so this usually just works and the cable
appears as a COM port. Check in Device Manager which COM number it got, and
point CX-Programmer's *Change PLC → Network Type: USB/Serial* at it.

Once the VID:PID is known, it can be pinned permanently instead of redirected
by hand each time — in virt-manager, **Add Hardware → USB Host Device**. Add
`startupPolicy='optional'` to that `<hostdev>` (via `virsh edit cxone`) or the
guest refuses to start whenever the cable is not plugged in, which is most of
the time.

#### Hubs, extenders, and which port

**No method used here binds to a physical port.** SPICE redirection keys on the
device you pick from the menu; a pinned `<hostdev>` keys on VID:PID. Both
follow the cable across ports and through hubs. Only the third form —
`<hostdev>` written against a bus/device *address* — is port-bound, and it is
not used here precisely because replugging breaks it.

So a hub or extender shared with a mouse and keyboard is fine. The hub stays
on the host; only the cable is redirected, and everything else on it keeps
working in Linux. The guest never sees the hub.

Two physical-layer caveats, which matter more than the virtualisation:

- **Do not extend the USB side.** USB is 5 m per passive segment. A USB-serial
  converter on a long passive run drops out intermittently, and the symptom is
  indistinguishable from a failing PLC link. Keep the converter near the
  laptop and extend the **RS-232 side** instead — good for ~15 m.
- **Use a powered hub** if the converter draws bus power.

And guard the keyboard: the redirect menu will hand it to the guest if
misclicked. A filter on the domain makes that impossible — `virsh edit cxone`,
inside `<devices>`:

```xml
<redirfilter>
  <usbdev class='0x03' allow='no'/>   <!-- HID: keyboards, mice -->
  <usbdev allow='yes'/>
</redirfilter>
```

### Which NIC is which

Windows names them `Ethernet` and `Ethernet 2` in detection order, which does
NOT match the order they are declared in the domain — do not guess. CX-One's
installer asks for one by name (its "Direct Ethernet Connection" network card
dialog), and picking the NAT NIC there quietly points the feature at a network
with no controller on it.

The DHCP lease settles it from the host side:

```fish
virsh -c qemu:///system net-dhcp-leases default   # MAC of the NAT NIC
virsh -c qemu:///system domiflist cxone           # MAC -> source mapping
```

Whichever guest NIC holds a `192.168.122.x` address is the NAT one. The PLC NIC
is the one showing `0.0.0.0`, because `br-plc` has no DHCP server by design.
As built, that came out as:

| Windows | Domain | Source | Address |
|---|---|---|---|
| `Ethernet 2` | `vnet0` | `default` (NAT) | `192.168.122.186` |
| `Ethernet`   | `vnet1` | `br-plc`         | `0.0.0.0` |

Two readings in that dialog that look wrong and are not: `0.0.0.0` is correct
and expected on the PLC NIC, and `Cable: Connected` is the *emulated* link
state — the guest cannot see whether `enp4s0` actually has a cable in it, so
it always reports connected. Neither means anything is broken.

"Direct Ethernet Connection" reaches the controller with raw layer-2 frames
rather than IP, which a bridge forwards transparently. That path also never
touches iptables, since the Docker `FORWARD DROP` trap above only applies to
IP — it still matters for ordinary FINS/UDP.

### Ethernet

Give the guest's second NIC (the `br-plc` one) a static address on the
controller's subnet, inside Windows. An NJ/CJ2 Ethernet port ships on
`192.168.250.1/24`, so `192.168.250.10/24`, no gateway, is the normal PC side.
Then *Change PLC → Network Type: Ethernet* (or EtherNet/IP on NJ/NX).

Leave the first NIC on DHCP — that is the NAT one, and it keeps the guest's
internet working independently.

---

## Traps

**Starting Docker kills the PLC bridge.** `br_netfilter` is loaded and
`bridge-nf-call-iptables` is `1`, so bridged frames traverse iptables FORWARD;
`dockerd` sets `iptables -P FORWARD DROP` on startup. `modules/vm-network.nix`
pins two explicit ACCEPTs for `br-plc` to survive this — if PLC traffic ever
dies right after a container session, check those rules survived:

```fish
sudo iptables -S FORWARD | grep br-plc     # expect two ACCEPT lines
```

**`enp4s0` is no longer a normal ethernet port.** It is enslaved to `br-plc`
and NetworkManager is told to ignore it, so an internet cable in that socket
will not bring the host online. See the note in `modules/vm-network.nix` for
how to get that back.

**Guest DNS depends on the leak guard's loopback exemption.** libvirt's dnsmasq
forwards to `127.0.0.53`, which the `dns-leak-guard` chain in
`modules/network.nix` lets through by the `-d 127.0.0.0/8 -j RETURN` rule. If
systemd-resolved is ever dropped and `/etc/resolv.conf` gains a real upstream,
the guest loses DNS while the host is fine.

**Windows activation.** A VM is different hardware from the dual-boot install,
so its digital licence does not follow. Unactivated Windows runs fine for this
— a watermark and no personalisation settings, nothing that affects CX-One.

**Do not boot the dual-boot partition as a VM.** It is tempting (CX-One is
already installed there) but `nvme0n1p1`, its ESP, is mounted read-write at
`/boot` on the host. Handing a partition to a guest while the host holds a
filesystem on the same ESP is how both get corrupted. A fresh guest is cheaper
than that recovery — see [`nixos-gpt-recovery.md`](nixos-gpt-recovery.md).
