{
  config,
  pkgs,
  lib,
  ...
}: {
  # List of packages to install for the user
  home.packages = with pkgs; [
    # Desktop packages now live in ./hyprland-dots.nix, which owns the
    # full dependency set for JaKooLit's dotfiles. `mako` was dropped in
    # the move: the dots start `swaync` instead, and running both daemons
    # would duplicate every notification.

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