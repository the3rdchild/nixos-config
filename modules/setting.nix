{ config, pkgs, ... }:
{
  # Garbage collection and store dedupe live in ./storage.nix.
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
