{ config, pkgs, lib, ... }:
{
  imports = [
    ./packages.nix
    ./shell.nix
    ./git.nix
    ./starship.nix
    ./kitty.nix
    ./mime.nix
    ./caelestia.nix
    ./onboard.nix
    ./themes.nix
    ./app-limits.nix
  ];

  home = {
    username = "noouoops";
    homeDirectory = "/home/noouoops";
    stateVersion = "24.11";
  };

  programs.home-manager.enable = true;
}
