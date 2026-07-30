# OpenPLC Runtime (v4) — manual / development install on NixOS.
#
# The runtime itself lives outside the Nix store, in
#   /mnt/doc/Programs/openplc-runtime
# (built per docs/NIXOS.md; build/ and venvs/runtime/ already exist).
# install.sh does not work on NixOS, so this module only covers the two
# pieces of state that the runtime expects from the OS:
#
#   1. The runtime socket directory /run/runtime. On NixOS /var/run is a
#      symlink to /run, which is a tmpfs, so the dir vanishes on every
#      reboot. The tmpfiles rule below recreates it automatically.
#
#   2. (Build deps live in modules/package.nix, not here.)
#
# Start the runtime manually (NIXOS.md step 6):
#   cd /mnt/doc/Programs/openplc-runtime
#   bash
#   source scripts/nixos-env.sh
#   sudo env "LD_LIBRARY_PATH=$LD_LIBRARY_PATH" ./start_openplc.sh
#
# systemd auto-start is intentionally NOT configured here — see the
# "Systemd service" section of docs/NIXOS.md (marked unverified).
{ ... }:

{
  systemd.tmpfiles.rules = [
    "d /run/runtime 0775 root root -"
  ];
}
