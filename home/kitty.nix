{
  config,
  pkgs,
  lib,
  ...
}: let
  themeSettings = import ./kitty-theme-settings.nix { inherit pkgs; };

  # dconf, not gsettings — see ../home/qt.nix and ./ii-session/light-dark.nix
  # for why: gsettings only reaches the real database with GIO_EXTRA_MODULES
  # pointed at dconf's GIO module, which this watcher's own environment does
  # not set up.
  themeSync = pkgs.writeShellScript "kitty-theme-sync" ''
    export PATH="${pkgs.dconf}/bin:$PATH"
    iface=/org/gnome/desktop/interface

    ${themeSettings}/bin/kitty-theme-settings
    dconf watch $iface/ | while read -r line; do
      [ "$line" = "$iface/color-scheme" ] && ${themeSettings}/bin/kitty-theme-settings
    done

    # Only reached if `dconf watch` died; fail so systemd restarts it.
    exit 1
  '';
in {
  home.packages = [ themeSettings ];

  home.activation.kittyTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${themeSettings}/bin/kitty-theme-settings
  '';

  systemd.user.services.kitty-theme-sync = {
    Unit = {
      Description = "Write kitty's light/dark theme when the session mode changes";
      After = [ "dconf.service" ];
    };
    Service = {
      ExecStart = "${themeSync}";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };

  programs.kitty = {
    enable = true;
    font = {
      name = "JetBrainsMono Nerd Font"; # Or your preferred Nerd Font
      size = 12;
    };
    # theme = ""; # Specify a theme name if desired
    settings = {
      # Basic settings - add more as needed
      scrollback_lines = 10000;
      enable_audio_bell = false;
      confirm_os_window_close = 0;
      background_opacity = "0.95";
      # Add your custom keybindings or other settings here
      # Example:
      # map ctrl+shift+v paste_from_clipboard
      # map ctrl+shift+c copy_to_clipboard
    };
    # Extra configuration can be added directly
    extraConfig = ''
      # Tab bar (not theme colours, so they live here rather than in the
      # generated include below)
      tab_bar_style fade
      tab_fade 1
      active_tab_font_style   bold
      inactive_tab_font_style bold

      # Everything that changes with light/dark mode: see
      # ./kitty-theme-settings.nix, which (re)writes this file whenever
      # org.gnome.desktop.interface color-scheme changes and reloads kitty.
      include theme-auto.conf
    '';
  };
}