# VS Code: follow the session's dark/light mode.
#
# WHY A WATCHER AFTER ALL
#   The section below was the original design and the portal half of it
#   still holds — but VS Code never acted on it live. Flipping color-scheme
#   emitted SettingChanged as described, and VS Code 1.129 (Electron 42) only
#   followed it towards dark; towards light it kept the dark theme until
#   restarted. (The light theme it was given, "Light+", also turned out to be
#   one VS Code silently refuses — see ./vscode-theme-settings.nix.) So vscode-theme-settings now writes
#   workbench.colorTheme itself (autoDetectColorScheme off), and
#   vscode-theme-sync re-runs it on every color-scheme change. VS Code
#   reloads settings.json on its own, which is what makes this live.
#
#   A theme picked by hand in VS Code is replaced at the next mode change;
#   change the two preferred* keys in ./vscode-theme-settings.nix instead.
#
# THE ORIGINAL DESIGN (no daemon)
#   `window.autoDetectColorScheme` makes it read
#   Electron's nativeTheme, which on Wayland comes from the XDG settings
#   portal key org.freedesktop.appearance/color-scheme — and that is already
#   wired up here: xdg-desktop-portal-gtk is the Settings backend (the
#   hyprland portal doesn't implement that interface, so it falls through to
#   gtk per hyprland-portals.conf), and it maps the same
#   org.gnome.desktop.interface color-scheme key that switchwall.sh's
#   pre_process() writes on every wallpaper change (see the dconf patch in
#   ./ii-session/light-dark.nix). Verified by watching SettingChanged: flipping the mode
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
#   seed-once mutablePaths in ./ii-session/default.nix: the app owns the file.
#
#   Which rules out a jq-style rewrite too — settings.json here is JSONC and
#   carries comments (the ntfs-3g/FUSE watcher exclusions), and every
#   whole-file JSON round trip silently eats them. Hence the surgical edit
#   below.
{ config, pkgs, lib, ... }:
let
  themeSettings = import ./vscode-theme-settings.nix { inherit pkgs; };

  # Both config roots: ~/.config for session A and ~/.config-ii for the ii
  # session (./ii-session). One watcher serves both because the dconf
  # database is shared between them.
  themeSync = pkgs.writeShellScript "vscode-theme-sync" ''
    export PATH="${pkgs.dconf}/bin:$PATH"
    iface=/org/gnome/desktop/interface

    apply() {
      for root in "$HOME/.config" "$HOME/.config-ii"; do
        [ -d "$root/Code/User" ] || continue
        XDG_CONFIG_HOME="$root" ${themeSettings}/bin/vscode-theme-settings
      done
    }

    apply
    dconf watch $iface/ | while read -r line; do
      [ "$line" = "$iface/color-scheme" ] && apply
    done

    # Only reached if `dconf watch` died; fail so systemd restarts it.
    exit 1
  '';
in
{
  # Also on PATH so the assertion can be re-run by hand after VS Code has
  # rewritten settings.json, without waiting for a rebuild.
  home.packages = [ themeSettings ];

  home.activation.vscodeTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${themeSettings}/bin/vscode-theme-settings
  '';

  # default.target for the same reason as gtk-theme-sync in ./themes.nix.
  systemd.user.services.vscode-theme-sync = {
    Unit = {
      Description = "Write VS Code's light/dark theme into settings.json when the session mode changes";
      After = [ "dconf.service" ];
    };
    Service = {
      ExecStart = "${themeSync}";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
