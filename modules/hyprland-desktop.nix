{ config, inputs, pkgs, ... }:
{
  # ── System-level support for the caelestia dots.
  #
  # The Hyprland package/session itself is enabled in ./package.nix; this
  # module only adds what has to exist outside home-manager. The per-user
  # half — the shell, the hypr Lua config, the app configs — lives in
  # ../home/caelestia.nix.
  #
  # Unlike the JaKooLit setup this replaced, ~/.config/hypr IS managed
  # declaratively now. Caelestia keeps its mutable state out of the config
  # tree (~/.local/state/caelestia) and confines runtime writes to
  # hypr/scheme/current.lua, so per-file symlinks work.

  # execs.lua drives cursor + GTK appearance through `gsettings`, which
  # needs a dconf backend to persist anything.
  programs.dconf.enable = true;

  # execs.lua starts polkit-gnome directly, but the policy daemon it talks
  # to still has to be running.
  security.polkit.enable = true;

  # gammastep's auto-location. The demo agent execs.lua launches is only the
  # client half — without the system service there is no provider to ask.
  services.geoclue2.enable = true;

  # NOTE: the lock screen does NOT need a security.pam.services entry. It
  # points PAM at its own config dir inside the package
  # (Quickshell.shellPath("assets/pam.d") in modules/lock/Pam.qml) rather
  # than /etc/pam.d, and authenticates via pam_unix + the setuid
  # unix_chkpwd helper NixOS already provides in /run/wrappers.

  environment.systemPackages = with pkgs; [
    polkit_gnome
    xdg-desktop-portal-hyprland
    xdg-desktop-portal-gtk # file pickers for GTK apps under Hyprland
    xdg-user-dirs # screenshot/recording paths resolve through this
  ];
}
