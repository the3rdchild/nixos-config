{ config, inputs, lib, pkgs, ... }:

{
  imports = [ inputs.silent-sddm.nixosModules.default ];

  # ── SilentSDDM.
  #
  # The module sets services.displayManager.sddm.enable, theme = "silent",
  # package (mkDefault kdePackages.sddm), extraPackages (the theme's
  # qtmultimedia / qtsvg / qtvirtualkeyboard / qtimageformats) and the
  # GreeterEnvironment that points QML2_IMPORT_PATH at the theme's components.
  # It also installs `test-sddm-silent`, which previews the configured theme in
  # a window — run it after a rebuild, before logging out.
  programs.silentSDDM = {
    enable = true;
    # One of configs/<name>.conf upstream: default, default-left,
    # default-right, rei, ken, silvia, catppuccin-{latte,frappe,macchiato,mocha},
    # eldritch-{abyss,cthulhu,dusk}, everforest, gruvbox, nord.
    theme = "default";

    # Backgrounds are copied into the theme's backgrounds/ directory at build
    # time, and the theme only ever loads "backgrounds/" + <name> — there is no
    # way to point it at an absolute path at runtime. The image lives in the
    # repo rather than being read from /mnt/shared because flake evaluation is
    # pure: an absolute path outside the flake is refused ("access to absolute
    # path ... is forbidden in pure evaluation mode"). It must be git-tracked
    # for the flake to see it at all.
    #
    # The attribute name is only a label; the file keeps its basename.
    backgrounds.chernobyl = ../assets/sddm/chernobyl.png;

    # Overrides on top of the preset. Keys map to [sections] of the conf file;
    # full list: https://github.com/uiriansan/SilentSDDM/wiki/Options
    settings = {
      "LockScreen".background = "chernobyl.png";
      "LoginScreen".background = "chernobyl.png";
    };
  };

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
  # hyprland-ii, the illogical-impulse session (./ii-session.nix). It is the
  # only session with a shell since caelestia was dropped, and the greeter
  # would otherwise keep defaulting to an entry that starts a bare compositor
  # with nothing drawn on top of it.
  #
  # It was "hyprland-uwsm" — the UWSM-managed entry — because the caelestia
  # session needed graphical-session.target for its user units. This session
  # deliberately does not run under UWSM (see ./ii-session.nix), and that
  # entry is now filtered out of the greeter entirely, there. The plain
  # "Hyprland" entry stays as the rollback: same compositor, no
  # XDG_CONFIG_HOME override, so it comes up bare but usable.
  services.displayManager.defaultSession = "hyprland-ii";

  services.displayManager.sddm = {
    autoNumlock = true;
    enableHidpi = true;

    wayland = {
      # mkForce: SilentSDDM's module sets wayland.enable = !xserver.enable at
      # normal priority, which with xserver enabled above is `false` and would
      # conflict with (or, without this line, silently undo) the Wayland
      # greeter.
      enable = lib.mkForce true;
      compositor = "kwin";
    };

    # Theme.Current is not set here: the sddm module derives it from `theme`,
    # which programs.silentSDDM sets to "silent".
    settings = {
      Theme = {
        CursorTheme = "Bibata-Modern-Ice";
        CursorSize = 24;
      };
    };
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

  # The theme package itself reaches ThemeDir through the SilentSDDM module's
  # environment.systemPackages; only the cursor theme is added here.
  environment.systemPackages = [ pkgs.bibata-cursors ];
}
