{ inputs, pkgs, ... }:
{
  programs.fish.enable = true;
  programs.hyprland = {
    enable = true;
    package = pkgs.hyprland;
  };

  environment.systemPackages = with pkgs; [
    kitty
    hyprland
    git
    fastfetch
    wget
    dpkg
    microsoft-edge
    firefox
    nodejs_22
    python312
    obsidian
    discord
    steam
    wireguard-ui
    flatpak
    qdirstat
    cameractrls
    obs-studio
    vscode
    localsend
    fanctl
  ];

  programs.nix-ld.enable = true;
}
