{
  config,
  pkgs,
  lib,
  ...
}: {
  # List of packages to install for the user
  home.packages = with pkgs; [
    # Desktop packages live in ./caelestia.nix, which owns the dependency
    # set for the caelestia dots. Note that the caelestia shell bundles most
    # of its own runtime deps (ddcutil, brightnessctl, lm_sensors, swappy,
    # libqalculate, fish) inside its wrapper — don't duplicate them here.

    # Utilities
    ripgrep
    fd
    fzf
    lazygit
    unzip
    wget
    # Fonts live in ../modules/fonts.nix (system-level) so SDDM and other
    # non-session consumers see them too. Caelestia's shell-specific fonts
    # stay in ./caelestia.nix.
  ];

  # Still needed: caelestia.nix installs fonts into the user profile.
  fonts.fontconfig.enable = true;
}