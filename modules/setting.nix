{ config, pkgs, ... }:
{
  # ── Garbage collection.
  #
  # options was "--max-old-generations 2", which is not a nix-collect-garbage
  # flag. It has never existed; the only ones that gate on age or count are
  # --delete-old, --delete-older-than and --max-freed. So the daily timer fired,
  # nix-collect-garbage rejected the argument, and the unit failed — every day,
  # silently, since the setting was written:
  #
  #   nix-gc-start[284768]: error: unrecognised flag '--max-old-generations'
  #   nix-gc.service: Failed with result 'exit-code'.
  #
  # Nothing was ever collected. By 2026-08-11 that had accumulated 108 system
  # generations and 103 GB of store across 53122 paths, against 29 GB actually
  # needed by the five newest generations plus home-manager. Roughly 74 GB of
  # the store was unreachable garbage that the daily job was supposed to have
  # taken and never did.
  #
  # --delete-older-than keeps a real rollback window rather than a generation
  # count. 30d is deliberate: the i915/nvidia_drm initrd deadlock in Aug 2026
  # took several generations of bisecting to pin down, and a too-eager GC would
  # have deleted the known-good generations that made that possible.
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 30d";
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # /etc/nixos is a symlink into the git repo rather than a second copy of the
  # config. The two used to be separate trees and silently diverged — package
  # edits landed only in /etc/nixos, module work only in the repo. Everything
  # now builds from /mnt/doc/config; this keeps the conventional path valid.
  #
  # /mnt/doc is NTFS-over-fuse (modules/filesystems.nix). If that mount is ever
  # missing the symlink dangles, but nixos-rebuild can still be pointed at a
  # store path or a generation directly, so it is not a recovery hazard.
  environment.etc."nixos".source = "/mnt/doc/config";

  # winboat (modules/package.nix) is an Electron app and nixpkgs still pins it
  # to electron 40.10.5, which upstream has marked EOL/insecure. Without this
  # the whole evaluation refuses. Drop this entry once winboat moves to a
  # supported electron, or remove winboat instead.
  nixpkgs.config.permittedInsecurePackages = [
    "electron-40.10.5"
  ];
  nix.settings.trusted-users = [ "root" "noouoops" ];

  # Don't pull every package's "doc" output into system-path.
  #
  # python312 exposes a sphinx-built doc output that fails to compile in the
  # current nixpkgs (docutils 0.23 breaks sphinx's enumerated-list parser:
  # "int() argument must be ... not 'NoneType'"), and it isn't in the binary
  # cache, so system-path can't build while `doc` is in
  # environment.extraOutputsToInstall.
  #
  # Only /share/doc HTML is dropped — man and info pages are untouched, and
  # every package itself stays installed. Set back to true once python3.12-doc
  # builds again upstream.
  documentation.doc.enable = false;
}
