#!/usr/bin/env bash
#
# Defines the CX-One Windows guest. Run once, as root:
#
#     sudo bash docs/cxone-vm-create.sh
#
# Root because the domain is defined on qemu:///system and the disk is created
# in /var/lib/libvirt/images, which the libvirtd group can manage but not
# create in. Afterwards the guest is yours to start/stop from virt-manager
# without sudo, via that group membership.
#
# Rationale for every choice here is in docs/cxone-vm.md; this file is meant to
# stay runnable, not to explain itself twice.
set -euo pipefail

# `--dry-run` validates the whole invocation — media readable, bridge present,
# storage pool usable, every virt-install argument accepted — without defining
# the domain or creating its disk. Note it DOES still set up the prerequisites
# (the default network and storage pool); those are idempotent and are needed
# for the validation to mean anything. Worth running first: the real run is not
# idempotent.
DRYRUN=()
if [[ ${1:-} == --dry-run ]]; then
  DRYRUN=(--dry-run)
  echo "(dry run: nothing will be defined)"
fi

ISO_DIR=/mnt/shared/VM/iso
WIN_ISO="$ISO_DIR/Win11-25H2-GhostSpectre-WPE.iso"
CXONE_ISO="$ISO_DIR/CX-One_V4.60.iso"
DISK=/var/lib/libvirt/images/cxone.qcow2
NAME=cxone

# Built by modules/libvirt.nix and exposed at a stable /etc path. Note this is
# NOT ${pkgs.virtio-win}/share/... — that package ships an extracted tree with
# no ISO in it at all; see the comment in the module.
VIRTIO_ISO=/etc/virtio-win.iso

for f in "$WIN_ISO" "$CXONE_ISO" "$VIRTIO_ISO"; do
  [[ -r $f ]] || { echo "missing or unreadable: $f" >&2; exit 1; }
done

if [[ ${#DRYRUN[@]} -eq 0 ]] && virsh --connect qemu:///system dominfo "$NAME" &>/dev/null; then
  echo "domain '$NAME' already exists — nothing to do." >&2
  echo "to start over:  sudo virsh undefine --nvram $NAME && sudo rm -f $DISK" >&2
  exit 1
fi

# libvirt ships the default NAT network but NixOS does not start it for you.
# This is the guest's route to the internet; br-plc (modules/vm-network.nix) is
# the separate, deliberately un-routed path to the controller.
# NOTE: the XML is inline rather than taken from the libvirt package. Upstream
# ships etc/libvirt/qemu/networks/default.xml, but the nixpkgs build does not
# install it (checked against libvirt 12.4.0), so there is no file on this
# system to point net-define at. libvirt fills in the uuid itself.
if ! virsh --connect qemu:///system net-info default &>/dev/null; then
  virsh --connect qemu:///system net-define /dev/stdin <<'XML'
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
XML
fi
virsh --connect qemu:///system net-start default 2>/dev/null || true
virsh --connect qemu:///system net-autostart default

# The 'default' storage pool, likewise absent on NixOS. pool-build creates the
# directory, so this also works on a machine that has not picked up the
# tmpfiles rule in modules/libvirt.nix yet. Without a pool, virt-install fails
# on the first --disk with "cannot open directory ... No such file or
# directory" rather than creating anything itself.
if ! virsh --connect qemu:///system pool-info default &>/dev/null; then
  virsh --connect qemu:///system pool-define-as default dir --target "$(dirname "$DISK")"
  virsh --connect qemu:///system pool-build default
fi
virsh --connect qemu:///system pool-start default 2>/dev/null || true
virsh --connect qemu:///system pool-autostart default

ip link show br-plc &>/dev/null || {
  echo "br-plc is missing — has nixos-rebuild switch run since modules/vm-network.nix landed?" >&2
  exit 1
}

virt-install "${DRYRUN[@]}" \
  --connect qemu:///system \
  --name "$NAME" \
  --osinfo win11 \
  --memory 4096 \
  --vcpus 4 \
  --cpu host-passthrough \
  --machine q35 \
  --boot uefi \
  --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
  --disk "path=$DISK,size=80,format=qcow2,bus=virtio,discard=unmap,boot.order=2" \
  --disk "device=cdrom,path=$WIN_ISO,bus=sata,readonly=on,boot.order=1" \
  --disk "device=cdrom,path=$VIRTIO_ISO,bus=sata,readonly=on" \
  --disk "device=cdrom,path=$CXONE_ISO,bus=sata,readonly=on" \
  --network network=default,model=e1000e \
  --network bridge=br-plc,model=e1000e \
  --graphics spice,listen=none \
  --video qxl \
  --channel spicevmc,target.type=virtio,target.name=com.redhat.spice.0 \
  --controller type=usb,model=qemu-xhci \
  --redirdev usb,type=spicevmc \
  --redirdev usb,type=spicevmc \
  --memballoon virtio \
  --sound none \
  --noautoconsole

echo
if [[ ${#DRYRUN[@]} -gt 0 ]]; then
  echo "dry run OK — nothing was defined. Re-run without --dry-run to create '$NAME'."
else
  echo "'$NAME' defined and started. Open virt-manager for the console."
fi
