{ config, inputs, pkgs, ... }:
{
  # ── System-level support for JaKooLit's Hyprland-Dots + HyprMod.
  #
  # The Hyprland package/session itself is enabled in ./package.nix. This
  # module only adds what the dotfiles expect to find system-wide.
  #
  # NOTE: ~/.config/hypr and ~/.config/waybar are deliberately NOT managed
  # by home-manager. The dots rewrite their own configs at runtime (wallust
  # recolouring, waybar style/config symlink switching, HyprMod's GUI writes)
  # and a nix-store symlink there is read-only, which breaks all three.
  # See home/default.nix for the removed imports.

  nixpkgs.overlays = [ inputs.hyprmod.overlays.default ];

  # initial-boot.sh and DarkLight.sh drive GTK appearance through `gsettings`,
  # which needs a dconf backend to persist anything.
  programs.dconf.enable = true;

  # scripts/Polkit-NixOS.sh scans /nix/store for the gnome polkit agent, so
  # the package has to actually be realised on the system.
  security.polkit.enable = true;

  environment.systemPackages = with pkgs; [
    polkit_gnome
    xdg-desktop-portal-gtk # file pickers for GTK apps under Hyprland
    xdg-user-dirs # dots call xdg-user-dir for Pictures/screenshot paths

    # scripts/Sounds.sh probes /run/current-system/sw/share/sounds for the
    # 'freedesktop' theme, so this has to be a system package — a home
    # package would land in /etc/profiles/per-user and be missed.
    sound-theme-freedesktop
  ];
}
