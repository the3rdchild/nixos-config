{ config, pkgs, lib, ... }:
{
  imports = [
    ./packages.nix
    ./shell.nix
    ./git.nix
    ./starship.nix
    ./kitty.nix
    ./hyprland-dots.nix

    # ./hyprland/default.nix and ./waybar.nix are intentionally NOT imported.
    #
    # Both rendered their config into the nix store and symlinked it into
    # ~/.config, which is read-only. JaKooLit's dots rewrite those same files
    # at runtime (wallust recolouring, waybar config/style switching) and
    # HyprMod appends its own `source =` line to hyprland.conf — none of which
    # works against a store symlink. The files are kept on disk so the old
    # declarative setup can be restored by re-adding these two imports.
  ];

  home = {
    username = "noouoops";
    homeDirectory = "/home/noouoops";
    stateVersion = "24.11";
  };

  programs.home-manager.enable = true;
}
