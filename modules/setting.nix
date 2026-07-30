{ config, pkgs, ... }:
{
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--max-old-generations 2";
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

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
