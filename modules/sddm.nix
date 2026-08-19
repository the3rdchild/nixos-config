{ config, pkgs, ... }:

let
  custom-sddm-astronaut = pkgs.sddm-astronaut.override {
    # astronaut, black_hole, cyberpunk, hyprland_kath, jake_the_dog,
    # japanese_aesthetic, pixel_sakura, pixel_sakura_static,
    # post-apocalyptic_hacker, purple_leaves
    embeddedTheme = "pixel_sakura";
  };

in {
  services.xserver.enable = true;

  # ── What plasma6 used to provide.
  #
  # services.desktopManager.plasma6 (dropped from ./service.nix) set three
  # things with mkDefault that this greeter actually relies on: SDDM's Wayland
  # mode, the kwin compositor it runs the greeter under, and defaultSession.
  # The option defaults underneath are wayland.enable = false and
  # compositor = "weston", so leaving them implicit would have quietly moved
  # the greeter back onto Xorg. Pinned here instead.
  #
  # "kwin" here means the kwin_wayland binary alone, not a Plasma session —
  # roughly one package, against the ~35 the desktop manager pulled in.
  #
  # The sddm-astronaut theme needs nothing from Plasma: the derivation
  # propagates its own qtsvg / qtmultimedia / qtvirtualkeyboard, and
  # services.displayManager.sddm.package already defaults to kdePackages.sddm.
  services.displayManager.defaultSession = "hyprland";

  services.displayManager.sddm = {
    enable = true;
    autoNumlock = true;
    enableHidpi = true;

    wayland = {
      enable = true;
      compositor = "kwin";
    };
    theme = "sddm-astronaut-theme";
    settings = {
      Theme = {
        Current = "sddm-astronaut-theme";
        CursorTheme = "Bibata-Modern-Ice";
        CursorSize = 24;
      };
    };
    extraPackages = with pkgs; [
      custom-sddm-astronaut
    ];
  };

  # ── The greeter's mouse cursor.
  #
  # The greeter runs as the `sddm` system user, so the only icon path it can
  # see is /run/current-system/sw/share/icons — never the per-user profile.
  # bibata-cursors is installed by home-manager (../home/themes.nix), which
  # puts it in /etc/profiles/per-user/noouoops and therefore out of reach:
  # CursorTheme above was in fact never resolving, and plasma6 was quietly
  # covering for it with breeze_cursors plus an xdg.icons fallback. Removing
  # plasma6 took both away and left the login screen with no cursor at all.
  #
  # So: install the theme system-wide as well (cheap — the store path is
  # shared with the home-manager copy, nothing is duplicated), and point the
  # xdg.icons fallback at it for anything that ignores CursorTheme.
  xdg.icons.fallbackCursorThemes = [ "Bibata-Modern-Ice" ];

  # accounts-daemon is how SDDM resolves user avatars for the greeter's user
  # list. plasma6 turned it on; restored here for the same reason as above.
  services.accounts-daemon.enable = true;

  # The theme has to land in ThemeDir (/run/current-system/sw/share/sddm/themes)
  # to be found; extraPackages alone only covers the greeter's own runtime
  # path. No Qt module is listed alongside it — the sddm-astronaut derivation
  # propagates qtsvg / qtmultimedia / qtvirtualkeyboard itself, so the explicit
  # kdePackages.qtmultimedia that used to sit here was redundant.
  environment.systemPackages = [
    custom-sddm-astronaut
    pkgs.bibata-cursors
  ];
}
