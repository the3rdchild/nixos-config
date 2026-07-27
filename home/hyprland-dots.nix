{
  config,
  pkgs,
  lib,
  ...
}: let
  # nixpkgs renamed swww -> awww. The dots invoke `swww` / `swww-daemon`
  # by name in ~40 places, so we re-expose those names.
  #
  # These link to the *inner* unwrapped ELFs on purpose. awww's bin/ entries
  # are shebang wrappers that `exec -a "$0"` into .awww-*-wrapped, and going
  # through them leaves /proc/<pid>/comm as "bash" — so the dots'
  # `pgrep -x swww-daemon` checks (WallustSwww.sh) never match and every run
  # tries to spawn another daemon. Linking to the ELF directly makes comm
  # follow the symlink name. The wrappers only prepend procps to PATH, which
  # is already present system-wide on NixOS.
  swww-compat = pkgs.runCommand "swww-compat-${pkgs.awww.version}" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.awww}/bin/.awww-wrapped        $out/bin/swww
    ln -s ${pkgs.awww}/bin/.awww-daemon-wrapped $out/bin/swww-daemon
  '';
in {
  # ── Runtime dependencies for JaKooLit's Hyprland-Dots (v2.3.20).
  #
  # The dots themselves are copied imperatively into ~/.config by their
  # copy.sh; this module only guarantees every binary those configs and
  # scripts shell out to actually exists on PATH.
  #
  # Deliberately excluded (see modules/hyprland-desktop.nix for why the
  # config dirs are unmanaged): anything that would write into
  # ~/.config/hypr or ~/.config/waybar.

  home.packages = with pkgs; [
    # Hypr ecosystem
    hyprlock
    hypridle
    hyprsunset
    hyprpicker
    hyprcursor

    # Theming engine — recolours waybar/rofi/kitty from the wallpaper
    wallust
    awww
    swww-compat # `swww` / `swww-daemon` names the dots expect

    # Bar, notifications, launcher, logout
    waybar
    swaynotificationcenter
    rofi # 'rofi-wayland' was merged into 'rofi' upstream
    wlogout

    # Clipboard
    cliphist
    wl-clipboard

    # Screenshots / annotation
    grim
    slurp
    satty
    swappy

    # Audio / media / backlight
    pamixer
    playerctl
    pavucontrol
    brightnessctl

    # Display + appearance helpers
    nwg-displays
    nwg-look

    # Quickshell overview (`qs -c overview`) and ags widgets
    quickshell
    ags

    # Live wallpaper + eye candy
    mpvpaper
    cava

    # Used throughout the dots' scripts
    bc # WallpaperSelect.sh sizes its rofi grid with it; hard-fails without
    btop
    fastfetch
    yad
    jq
    imagemagick
    ffmpeg
    libnotify
    python3

    # Tray applets started from Startup_Apps.conf
    networkmanagerapplet
    blueman

    # Themes referenced by initial-boot.sh's gsettings calls
    flat-remix-gtk
    flat-remix-icon-theme
    bibata-cursors

    # GTK4 settings GUI. Provided by the overlay added in
    # modules/hyprland-desktop.nix; writes only to its own
    # ~/.config/hypr/hyprland-gui.conf.
    hyprmod
  ];
}
