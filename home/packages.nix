{
  config,
  pkgs,
  lib,
  ...
}: {
  # List of packages to install for the user.
  #
  # Session-specific packages do NOT belong here: everything the illogical-
  # impulse session reaches by name lives in ./ii-session.nix, next to the
  # dots that call it. The split is deliberate — a package moved out of that
  # file breaks a keybind or a panel, while one moved out of this file only
  # takes a convenience away from a shell prompt.
  home.packages = with pkgs; [
    # Utilities
    ripgrep
    fd
    fzf
    lazygit
    unzip
    wget

    # ── Desktop tools inherited from the dropped caelestia session.
    #
    # These are the half of ../home/caelestia.nix's package list that was
    # never caelestia-specific: general desktop programs that happened to be
    # declared next to the dots that shipped its config. Nothing in
    # ./ii-session.nix calls any of them by name, which is exactly why they
    # are here and not there.
    foot # fallback terminal; kitty (../modules/package.nix) is the SUPER+T default
    btop
    fastfetch
    micro
    hyprpicker # colour picker, handy from any session
    pavucontrol # GTK mixer; pwvucontrol (./ii-session.nix) is the bound one
    trash-cli
    gammastep # night light, by hand — hyprsunset is what the shell drives
    bluez # mpris-proxy, forwards Bluetooth media keys to MPRIS
    wireplumber # wpctl, which the volume keybinds call
    glib # gsettings — see ../modules/hyprland-desktop.nix for the schemas
         # that make it able to read anything

    # ── Display arranging.
    #
    # nwg-displays is the drag-and-drop arranger: resolution, refresh rate,
    # scale, transform, mirror, enable/disable. It writes monitors.conf plus a
    # matching monitors.lua, and the illogical-impulse dots ship their own
    # monitor configurator alongside it (hypr/monitors.lua, in mutablePaths).
    nwg-displays
    wlr-randr # kept for scripting — `wlr-randr --output X --off` in a one-off
              # shell is still handier than a GUI.

    # Fonts live in ../modules/fonts.nix and ../modules/ii-session.nix
    # (system-level) so SDDM and the session's own fontconfig both see them.
    # A font in this list would be advertised through
    # ~/.config/fontconfig/conf.d/10-hm-fonts.conf, which the session's
    # alternate config root never reads.
  ];

  fonts.fontconfig.enable = true;
}
