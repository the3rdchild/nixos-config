# VS Code: follow the session's dark/light mode.
#
# HOW IT WORKS WITHOUT ANY DAEMON
#   VS Code does this itself. `window.autoDetectColorScheme` makes it read
#   Electron's nativeTheme, which on Wayland comes from the XDG settings
#   portal key org.freedesktop.appearance/color-scheme — and that is already
#   wired up here: xdg-desktop-portal-gtk is the Settings backend (the
#   hyprland portal doesn't implement that interface, so it falls through to
#   gtk per hyprland-portals.conf), and it maps the same
#   org.gnome.desktop.interface color-scheme key that switchwall.sh's
#   pre_process() writes on every wallpaper change (see the dconf patch in
#   ./ii-session.nix). Verified by watching SettingChanged: flipping the mode
#   emits
#   org.freedesktop.appearance/color-scheme = 1 for dark, 2 for light.
#
#   So unlike the Qt side (./qt.nix) there is nothing to watch and nothing to
#   translate — only three settings to put in place.
#
# WHY NOT programs.vscode
#   home-manager writes settings.json as a symlink into the store. VS Code
#   then cannot save ANY setting from its own UI, and this file is almost
#   entirely settings that were set that way. Same reasoning as the
#   seed-once mutablePaths in ./ii-session.nix: the app owns the file.
#
#   Which rules out a jq-style rewrite too — settings.json here is JSONC and
#   carries comments (the ntfs-3g/FUSE watcher exclusions), and every
#   whole-file JSON round trip silently eats them. Hence the surgical edit
#   below.
{ config, pkgs, lib, ... }:
let
  themeSettings = import ./vscode-theme-settings.nix { inherit pkgs; };
in
{
  # Also on PATH so the assertion can be re-run by hand after VS Code has
  # rewritten settings.json, without waiting for a rebuild.
  home.packages = [ themeSettings ];

  home.activation.vscodeTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${themeSettings}/bin/vscode-theme-settings
  '';
}
