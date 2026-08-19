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

  # The theme has to land in ThemeDir (/run/current-system/sw/share/sddm/themes)
  # to be found; extraPackages alone only covers the greeter's own runtime
  # path. No Qt module is listed alongside it — the sddm-astronaut derivation
  # propagates qtsvg / qtmultimedia / qtvirtualkeyboard itself, so the explicit
  # kdePackages.qtmultimedia that used to sit here was redundant.
  environment.systemPackages = [ custom-sddm-astronaut ];
}
