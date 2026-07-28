{
  config,
  inputs,
  pkgs,
  lib,
  ...
}: let
  # ── Upstream dots, patched for NixOS.
  #
  # caelestia-dots/caelestia is an Arch-first repo: its installer is driven
  # by a manifest.toml full of pacman names, and a few paths are hardcoded
  # to the FHS. We don't use the installer at all — we take the config files
  # and rewrite the three paths that don't exist here. Everything else is
  # upstream-verbatim, so `nix flake update caelestia-dots` is a safe bump.
  dots = pkgs.runCommand "caelestia-dots-nixos" { } ''
    cp -r ${inputs.caelestia-dots} $out
    chmod -R u+w $out

    # execs.lua spawns the polkit agent and geoclue's demo agent from
    # /usr/lib. Both silently no-op on NixOS, which costs you every polkit
    # prompt (mounting disks, nmtui) and gammastep's auto-location.
    substituteInPlace $out/hypr/hyprland/execs.lua \
      --replace-fail \
        '/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1' \
        '${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1' \
      --replace-fail \
        '/usr/lib/geoclue-2.0/demos/agent' \
        '${pkgs.geoclue2-with-demo-agent}/libexec/geoclue-2.0/demos/agent'

    # QT_QPA_PLATFORMTHEME=qtengine — qtengine is AUR-only. qt6ct is the
    # same idea (Qt platform theme reading a config file) and is packaged.
    substituteInPlace $out/hypr/hyprland/env.lua \
      --replace-fail '"QT_QPA_PLATFORMTHEME", "qtengine"' '"QT_QPA_PLATFORMTHEME", "qt6ct"'
  '';

  # Configs their own app rewrites at runtime. A nix-store symlink is
  # read-only, so these get *copied* once and then left alone — the same
  # trap that made JaKooLit's dots unmanageable. Losing declarative
  # ownership here is the price of the app being able to save its state.
  mutableConfigs = {
    "btop/btop.conf" = "${dots}/btop/btop.conf";
    "micro/settings.json" = "${dots}/micro/settings.json";
  };

  # The `qs` CLI, which keybinds.lua uses to kill/restart the shell
  # (CTRL+SUPER+SHIFT+R and CTRL+SUPER+ALT+R). The shell derivation bundles
  # quickshell inside its own wrapper, so nothing puts `qs` on PATH.
  #
  # This MUST be the exact quickshell the shell was built against, with the
  # same overrides as shell/flake.nix applies — nixpkgs' tagged quickshell is
  # a different build and its IPC would not match the running instance.
  # Mirrors shell/nix/default.nix exactly, down to the withModules call —
  # anything less produces a different store path than the one the running
  # shell was launched from.
  quickshell =
    (inputs.caelestia-shell.inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
      withX11 = false;
      withI3 = false;
    }).withModules [ pkgs.qt6.qtimageformats ];
  # NOTE: there used to be a fuzzel-based `caelestia-wallpaper-picker` here.
  # It was removed because fuzzel is text-only and can't show wallpaper
  # thumbnails. The SUPER+SHIFT+W keybind now opens caelestia's built-in
  # `nexus` settings panel (caelestia:nexus global shortcut), which has a
  # real wallpaper picker with image previews AND live scheme previewing.
  # See modules/nexus/pages/wallandstyle/WallpaperSelect.qml in the shell.
in {
  imports = [ inputs.caelestia-shell.homeManagerModules.default ];

  # ── The shell (bar, launcher, notifications, lock screen, OSDs).
  #
  # systemd.enable = false is deliberate: the hypr config already starts the
  # shell from execs.lua (`caelestia shell -d`), and the CTRL+SUPER+SHIFT+R
  # keybind restarts it the same way. Running the systemd unit as well gives
  # you two shells fighting over the same layer surfaces.
  programs.caelestia = {
    enable = true;
    cli.enable = true;
    systemd.enable = false;
  };

  xdg.configFile = {
    # recursive = true is load-bearing. A plain directory source symlinks
    # the whole tree read-only; recursive creates real directories and
    # symlinks each file, which leaves room for hyprland.lua to write
    # scheme/current.lua and for `caelestia scheme` to rewrite it later.
    "hypr" = {
      source = "${dots}/hypr";
      recursive = true;
    };

    # Read by the app, never written by it — safe as store symlinks.
    "foot/foot.ini".source = "${dots}/foot/foot.ini";
    "fastfetch/config.jsonc".source = "${dots}/fastfetch/config.jsonc";

    # User overrides, merged over hypr/variables.lua by hyprland.lua.
    # Upstream only creates this as an empty stub, so owning it is free.
    "caelestia/hypr-vars.lua".text = ''
      -- Managed by home/caelestia.nix. Overrides hypr/variables.lua.
      return {
          terminal     = "foot",
          browser      = "firefox",
          editor       = "code",
          fileExplorer = "thunar",

          -- Kept in sync with themes.active (see home/themes.nix); upstream
          -- defaults to sweet-cursors, which isn't in nixpkgs.
          cursorTheme  = "${config.themes.activeCursor}",
          cursorSize   = 24,
      }
    '';

    # Sourced by caelestia's fish config for machine-local additions. Our
    # aliases live in home/shell.nix instead, so this just has to exist.
    "caelestia/user-config.fish".text = "";

    # ── User Hyprland overrides, sourced at the END of caelestia's
    # hyprland.lua (lines 74-76: maybe_create + require("hypr-user")).
    #
    # Only place for extra binds/window-rules that aren't driven by a
    # `variables.lua` key. Don't duplicate upstream binds — last-wins in
    # Hyprland, so this can also rebind an existing combo by reusing it.
    #
    # SUPER+SHIFT+W opens caelestia's `nexus` settings panel — a full GUI
    # wallpaper picker with image thumbnails AND live scheme previewing (it
    # generates the colours from each hovered wallpaper before you commit).
    # This is a quickshell global shortcut registered by the shell; caelestia
    # ships no default keybind for it, so we add one here. Once nexus is open,
    # navigate to the "Wallpaper" tab.
    #
    # Keyboard backlight (acer_ec::kbd_backlight). The acer-ec module already
    # installs brightnessctl, the acer-kbd-toggle script, and a udev rule
    # granting the video group write access to the LED. These binds just hook
    # it to keys — no widget possible (bar is compiled QML; see caelestia
    # notes).
    #
    # Keys chosen to avoid upstream conflicts: SUPER+ALT+arrows are window
    # resize, SUPER+K is showall panels, so we use the entirely-free
    # SUPER+CTRL plane. Up/Down step ±10%, K toggles off.
    "caelestia/hypr-user.lua".text = ''
      local vars = require("variables")
      hl.bind("SUPER + SHIFT + W", hl.dsp.global("caelestia:nexus"))
      hl.bind("SUPER + CTRL + up", hl.dsp.exec_cmd("brightnessctl -d acer_ec::kbd_backlight set +10%"), { repeating = true })
      hl.bind("SUPER + CTRL + down", hl.dsp.exec_cmd("brightnessctl -d acer_ec::kbd_backlight set 10%-"), { repeating = true })
      hl.bind("SUPER + CTRL + K", hl.dsp.exec_cmd("acer-kbd-toggle"))
    '';
  };

  home.packages = with pkgs; [
    # Terminal + launcher. kitty stays in modules/package.nix; foot is the
    # SUPER+T default because caelestia recolours it through the escape
    # sequences fish replays from ~/.local/state/caelestia/sequences.txt.
    foot
    fuzzel # SUPER+V clipboard, SUPER+. emoji picker, SUPER+SHIFT+W wallpaper

    # TUI apps themed by the caelestia scheme
    btop
    fastfetch
    micro

    # Launched from execs.lua / bound in keybinds.lua
    thunar
    hyprpicker
    pavucontrol # CTRL+ALT+V (vars.audioSettings)
    libnotify # notify-send, used by the shell and the F12 test bind
    quickshell # `qs` — see the let block above
    cliphist
    wl-clipboard
    trash-cli # `trash-empty 30` on session start
    gammastep # night light
    geoclue2-with-demo-agent # location provider for gammastep
    gnome-keyring
    bluez # mpris-proxy, forwards BT media keys to MPRIS
    wireplumber # wpctl, volume keybinds
    glib # gsettings, used by execs.lua for cursor

    # Qt theming — replaces the AUR-only qtengine referenced by env.lua
    qt6Packages.qt6ct
    darkly

    # Fonts the shell's QML expects. The shell derivation builds its own
    # fontconfig for its process, but nothing else on the system sees it.
    material-symbols
    nerd-fonts.caskaydia-cove
    rubik
  ];

  # ── Copy-once configs (see mutableConfigs above).
  home.activation.caelestiaMutableConfigs =
    lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatStringsSep "\n" (
        lib.mapAttrsToList (dest: src: ''
          if [ ! -e "${config.xdg.configHome}/${dest}" ]; then
            run mkdir -p "$(dirname "${config.xdg.configHome}/${dest}")"
            run cp ${src} "${config.xdg.configHome}/${dest}"
            run chmod u+w "${config.xdg.configHome}/${dest}"
          fi
        '') mutableConfigs
      )
    );

  # ── Firefox chrome theme.
  #
  # Firefox profile directories are named with a random prefix, so the
  # destination can't be known at eval time — hence the glob. Skipped
  # entirely until a profile exists; run Firefox once, then rebuild.
  home.activation.caelestiaFirefox =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      for profile in "$HOME"/.mozilla/firefox/*.default*/; do
        [ -d "$profile" ] || continue
        run mkdir -p "$profile/chrome"
        run cp -f ${dots}/firefox/userChrome.css "$profile/chrome/userChrome.css"
        run cp -f ${dots}/firefox/user.js "$profile/user.js"
        run chmod u+w "$profile/chrome/userChrome.css" "$profile/user.js"
      done
    '';

  # ── Wallpaper source dir for the nexus picker and `caelestia wallpaper -r`.
  #
  # The shell's nexus wallpaper picker (SUPER+SHIFT+W -> caelestia:nexus) and
  # `caelestia wallpaper -r` both pull from here (CAELESTIA_WALLPAPERS_DIR
  # default; see paths.py / Paths.qml). Created empty on every rebuild so the
  # picker never errors — drop images in by hand. Idempotent: mkdir -p is a
  # no-op once it exists.
  home.activation.caelestiaWallpapersDir =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p "$HOME/Pictures/Wallpapers"
    '';
}
