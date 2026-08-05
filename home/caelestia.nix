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

    # gestures.lua binds a 4-finger swipe-down to `systemctl
    # suspend-then-hibernate` (vars.sleepGestureCmd). Far too easy to trigger
    # by accident on a laptop touchpad, so the whole gesture block is dropped
    # here. The SUPER+SHIFT+L keybind in keybinds.lua still sleeps — this
    # patch is scoped to gestures.lua, and `vars.sleepGestureCmd` stays
    # defined. The $'...' form makes bash expand \n into real newlines so the
    # multi-line block matches literally; --replace-fail makes a reformat in
    # upstream fail loudly instead of silently keeping the gesture.
    substituteInPlace $out/hypr/hyprland/gestures.lua \
      --replace-fail $'hl.gesture({\n    fingers   = vars.gestureFingersMore,\n    direction = "down",\n    action    = function()\n        hl.exec_cmd(vars.sleepGestureCmd)\n    end,\n})' ""
  '';

  # Configs their own app rewrites at runtime. A nix-store symlink is
  # read-only, so these get *copied* once and then left alone — the same
  # trap that made JaKooLit's dots unmanageable. Losing declarative
  # ownership here is the price of the app being able to save its state.
  mutableConfigs = {
    "btop/btop.conf" = "${dots}/btop/btop.conf";
    "micro/settings.json" = "${dots}/micro/settings.json";

    # nwg-displays keys its saved rules on port name by default, which is
    # exactly wrong here: the TV and the projector are both HDMI-A-1, so a
    # name-keyed rule would push the TV's 180Hz onto the projector. use-desc
    # switches it to `desc:<edid description>` rules, matching what the Nexus
    # Display page and the monitors.lua loader expect.
    #
    # Only this one key is seeded — nwg-displays fills the rest from its own
    # defaults on first run (config_keys_missing in tools.py) and rewrites the
    # whole file whenever you toggle something in its UI, which is why this is
    # copy-once rather than a store symlink.
    "nwg-displays/config" = pkgs.writeText "nwg-displays-config" (
      builtins.toJSON { use-desc = true; }
    );
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
  # ── The shell, with a Display page added to nexus.
  #
  # Upstream stubbed this page out and never built it — PageRegistry.qml still
  # carries the commented-out entry with a `// TODO` above it. Hyprland owns
  # monitor config, so there was nowhere in the GUI to change a refresh rate.
  #
  # Patching this is much cheaper than it looks: CMakeLists.txt installs
  # modules/, services/ and components/ with a plain `install(DIRECTORY ...)`
  # and the wrapper runs `qs -p $out/share/caelestia-shell`. The QML is copied
  # verbatim, not compiled — only plugin/ and extras/ are C++. So this adds
  # files and rewrites two registries; nothing here triggers a C++ rebuild.
  #
  # The two registries are INDEX-ALIGNED: PageRegistry.pages[i] is the nav
  # entry for PageCompRegistry.pageComps[i]. Both --replace-fail anchors are
  # written to break loudly if upstream reorders the list, because a silent
  # misalignment shows the right nav label over the wrong page.
  shellSrc = pkgs.runCommand "caelestia-shell-src-display" { } ''
    cp -r ${inputs.caelestia-shell} $out
    chmod -R u+w $out

    cp ${./caelestia/shell/services/Monitors.qml} $out/services/Monitors.qml
    mkdir -p $out/modules/nexus/pages/display
    cp ${./caelestia/shell/modules/nexus/pages/display}/*.qml \
      $out/modules/nexus/pages/display/

    # Uncomment the nav entry upstream left behind.
    substituteInPlace $out/modules/nexus/PageRegistry.qml --replace-fail \
      '        // Connectivity
        // TODO
        // {
        //     label: qsTr("Display"),
        //     icon: "monitor",
        //     description: qsTr("Output configuration"),
        //     category: "connectivity"
        // },' \
      '        // Connectivity
        {
            label: qsTr("Display"),
            icon: "monitor",
            description: qsTr("Resolution, refresh rate, arrangement"),
            category: "connectivity"
        },'

    substituteInPlace $out/modules/nexus/PageCompRegistry.qml \
      --replace-fail \
        'import qs.modules.nexus.pages.bluetooth' \
        'import qs.modules.nexus.pages.bluetooth
import qs.modules.nexus.pages.display' \
      --replace-fail \
        '        // Connectivity
        Component {
            // Network' \
        '        // Connectivity
        Component {
            // Display
            StackPage {
                Component {
                    DisplayPage {}
                }
                Component {
                    MonitorDetail {}
                }
            }
        },
        Component {
            // Network'

    # ── Keep rounded corners in game mode.
    #
    # services/GameMode.qml applies one fixed bundle of Hyprland overrides in
    # setDynamicConfs(): animations, blur, shadows, gaps, border size, tearing
    # — and rounding. Game mode is worth keeping on this hardware (Alder Lake-P
    # GT1 driving 1920x1080@144 + 1920x1080@180 = ~672 Mpix/s, where the iGPU
    # sits pinned at its 300MHz efficiency floor and never goes idle), but the
    # rounding term is the odd one out: it is a cheap fragment-shader term,
    # while the measured GPU cost is in blur and per-frame compositing. Square
    # corners were the only part of game mode that looked wrong, for no
    # meaningful frame-time gain, so that one line is dropped.
    #
    # Scoped deliberately: gaps_in/gaps_out/border_size stay in the bundle.
    #
    # Safe against the toggle's own state readback — the PersistentProperties
    # binding keys `enabled` on Hypr.options["animations:enabled"] === 0, not
    # on rounding, so the on/off state still round-trips correctly. Disabling
    # game mode restores everything via Hypr.extras.message("reload") anyway.
    #
    # --replace-fail so an upstream reorder or reindent of that object breaks
    # the build instead of silently restoring the square corners.
    substituteInPlace $out/services/GameMode.qml \
      --replace-fail $'            "decoration:rounding": 0,\n' ""
  '';

  # Rebuild from the patched tree rather than overriding the flake's package:
  # nix/default.nix hardcodes `src = ./..` on four separate derivations, so
  # there is no `src` argument to override. callPackage on the copy makes
  # `./..` resolve inside it instead.
  #
  # Every argument here mirrors caelestia-shell's own flake.nix. They are not
  # defaults — clangStdenv and the withX11/withI3-disabled quickshell are what
  # upstream builds against, and using nixpkgs' quickshell instead produces a
  # binary whose IPC does not match. withCli = true matches the `with-cli`
  # output the home-manager module defaults to.
  caelestiaShell = pkgs.callPackage "${shellSrc}/nix" {
    inherit (inputs.caelestia-shell.inputs) m3shapes;
    rev = inputs.caelestia-shell.rev or inputs.caelestia-shell.dirtyRev;
    stdenv = pkgs.clangStdenv;
    quickshell =
      inputs.caelestia-shell.inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
        withX11 = false;
        withI3 = false;
      };
    caelestia-cli =
      inputs.caelestia-shell.inputs.caelestia-cli.packages.${pkgs.stdenv.hostPlatform.system}.default;
    withCli = true;
  };

  # NOTE: there used to be a fuzzel-based `caelestia-wallpaper-picker` here.
  # It was removed because fuzzel is text-only and can't show wallpaper
  # thumbnails. The SUPER+SHIFT+P keybind now opens caelestia's built-in
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

    # The nexus Display page (see shellSrc above). Everything else about this
    # package is upstream's own build.
    package = caelestiaShell;
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
          fileExplorer = "dolphin",

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
    # SUPER+SHIFT+P opens caelestia's `nexus` settings panel — the wallpaper
    # picker with image thumbnails and live scheme previewing (it generates
    # the colours from each hovered wallpaper before you commit), and the
    # Display page added in shellSrc above. This is a quickshell global
    # shortcut registered by the shell; caelestia ships no default keybind for
    # it, so we add one here.
    #
    # P for the Win+P muscle memory, since Display is the page most worth
    # reaching in a hurry. Plain SUPER+P is taken — it's upstream's
    # kbPinWindow (variables.lua:79) — and SUPER+SHIFT is where caelestia
    # already puts panel/tool invocations (SHIFT+S screenshot, SHIFT+C colour
    # picker, SHIFT+L sleep), so this sits with its neighbours rather than in
    # the SUPER+ALT resize plane or the SUPER+CTRL backlight plane below.
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
      -- Disable SUPER+W (upstream kbBrowser → launches firefox).
      --
      -- Must be unbind, not a no_op rebind: Hyprland dispatches EVERY keybind
      -- matching a combo, it is not last-wins. A second bind on SUPER+W just
      -- adds a no-op next to the firefox one, and firefox still launches
      -- (`hyprctl binds` showed two modmask-64 W entries). hl.unbind removes
      -- all binds for the combo, and hypr-user.lua runs after keybinds.lua so
      -- the upstream bind already exists by this point.
      hl.unbind("SUPER + W")
      hl.bind("SUPER + SHIFT + P", hl.dsp.global("caelestia:nexus"))
      hl.bind("SUPER + CTRL + up", hl.dsp.exec_cmd("brightnessctl -d acer_ec::kbd_backlight set +10%"), { repeating = true })
      hl.bind("SUPER + CTRL + down", hl.dsp.exec_cmd("brightnessctl -d acer_ec::kbd_backlight set 10%-"), { repeating = true })
      hl.bind("SUPER + CTRL + K", hl.dsp.exec_cmd("acer-kbd-toggle"))

      -- ── Display / monitor configuration.
      --
      -- Hyprland's Lua parser refuses `hyprctl keyword` outright ("keyword
      -- can't work with non-legacy parsers. Use eval."), so every runtime
      -- monitor change has to go through `hyprctl eval`, and anything that
      -- must survive a reload has to live in a file this config loads.
      --
      -- ~/.config/hypr/monitors.lua is that file, and it is deliberately NOT
      -- managed by home-manager: it's the one thing a GUI has to be able to
      -- write. Two writers, one format — both emit plain hl.monitor{} calls:
      --   * nwg-displays, which writes monitors.conf AND monitors.lua on every
      --     apply (settings_applier.py). The .conf half is inert under the Lua
      --     parser; the .lua half is what we load here.
      --   * the Nexus Display page, which writes the same file and *also*
      --     applies live over `eval` so changes show up without a reload.
      --
      -- Rules are keyed on `desc:` rather than port name because the TV and
      -- the projector are both HDMI-A-1 — a name-keyed rule would shove the
      -- TV's 180Hz onto a projector that can't display it.
      --
      -- loadfile rather than require/dofile on purpose: a missing file is a
      -- silent no-op (first boot, or before anything has been saved), and a
      -- syntax error from a half-written GUI save returns nil instead of
      -- raising. The pcall then keeps one bad monitor rule from taking the
      -- whole Hyprland config — and your session — down with it.
      local monitorsFile = os.getenv("HOME") .. "/.config/hypr/monitors.lua"
      local monitorsChunk = loadfile(monitorsFile)
      if monitorsChunk then
          local ok, err = pcall(monitorsChunk)
          if not ok then
              print("[hypr-user] monitors.lua failed to apply: " .. tostring(err))
          end
      else
          -- No saved layout yet. Upstream's catch-all (hyprland.lua:54) uses
          -- mode="preferred", which takes the EDID preferred mode. On the FAZ
          -- 27" that is 60Hz even though the panel advertises 180Hz; the
          -- laptop's eDP-1 happens to prefer its full 144Hz, so only the
          -- external was affected. highrr picks the highest refresh rate at
          -- the best resolution instead.
          --
          -- Only reached when monitors.lua is absent: once a layout is saved,
          -- its explicit per-output entries cover everything that's plugged
          -- in, and re-running a catch-all here would fight them (setting one
          -- output re-runs position="auto" for the others and reflows the
          -- whole layout).
          hl.monitor({ output = "", mode = "highrr", position = "auto", scale = 1 })
      end
    '';
  };

  home.packages = with pkgs; [
    # Terminal + launcher. kitty stays in modules/package.nix; foot is the
    # SUPER+T default because caelestia recolours it through the escape
    # sequences fish replays from ~/.local/state/caelestia/sequences.txt.
    foot
    fuzzel # SUPER+V clipboard, SUPER+. emoji picker

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
    # ── Display arranging.
    #
    # nwg-displays is the drag-and-drop arranger: resolution, refresh rate,
    # scale, transform, mirror, enable/disable. It's the fallback for anything
    # the Nexus Display page doesn't cover, and the reference implementation
    # the page's writer is modelled on.
    #
    # It needs the monitors.lua loader in hypr-user.lua to do anything here.
    # Its own apply path is `write monitors.conf` + `hyprctl reload`, and the
    # Lua parser never sources a .conf — so without that loader every change
    # would look applied and then vanish on the next reload. It does emit a
    # matching monitors.lua (settings_applier.py), which is what we read.
    nwg-displays
    wlr-randr # kept for scripting — `wlr-randr --output X --off` in a one-off
              # shell is still handier than a GUI. Not the arranger any more.
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
  # The shell's nexus wallpaper picker (SUPER+SHIFT+P -> caelestia:nexus) and
  # `caelestia wallpaper -r` both pull from here (CAELESTIA_WALLPAPERS_DIR
  # default; see paths.py / Paths.qml). Created empty on every rebuild so the
  # picker never errors — drop images in by hand. Idempotent: mkdir -p is a
  # no-op once it exists.
  home.activation.caelestiaWallpapersDir =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p "$HOME/Pictures/Wallpapers"
    '';
}
