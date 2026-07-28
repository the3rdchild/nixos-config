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
    # Fonts (ensure noto-fonts-cjk-sans is included if needed for CJK)
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji # renamed from noto-fonts-emoji
    nerd-fonts.fira-code
    nerd-fonts.jetbrains-mono
    nerd-fonts.iosevka
  ];

  # Font configuration
  fonts.fontconfig.enable = true;
}