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
    #
    # The polkit agent is also wrapped in unless-uwsm (see the let block
    # below): under UWSM it runs as services.polkit-gnome instead.
    substituteInPlace $out/hypr/hyprland/execs.lua \
      --replace-fail \
        '/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1' \
        '${unlessUwsm}/bin/unless-uwsm ${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1' \
      --replace-fail \
        '/usr/lib/geoclue-2.0/demos/agent' \
        '${pkgs.geoclue2-with-demo-agent}/libexec/geoclue-2.0/demos/agent'

    # ── Shell and clipboard watchers: systemd units under UWSM, execs.lua in
    # the plain session.
    #
    # Under UWSM the shell, polkit agent and both cliphist watchers are user
    # units (programs.caelestia.systemd, services.polkit-gnome,
    # services.cliphist below), so they get Restart=, ordering and logs in
    # `journalctl --user`. They hang off graphical-session.target, which the
    # plain "Hyprland" fallback session never reaches. So the execs.lua lines
    # stay, gated instead of deleted: unless-uwsm makes them no-ops under
    # UWSM, and in the fallback session they run exactly as upstream wrote
    # them. Deleting them would leave the fallback with no bar, launcher,
    # session menu, polkit prompts or clipboard history.
    #
    # The wl-paste anchor matches both watcher lines (text and image).
    substituteInPlace $out/hypr/hyprland/execs.lua \
      --replace-fail \
        'hl.exec_cmd("wl-paste --type' \
        'hl.exec_cmd("${unlessUwsm}/bin/unless-uwsm wl-paste --type' \
      --replace-fail \
        'hl.exec_cmd("caelestia shell -d")' \
        'hl.exec_cmd("${shellUp}/bin/caelestia-shell-up")'

    # keybinds.lua starts the shell in two places: CTRL+SUPER+ALT+R (kill,
    # then start) and vars.kbRestoreLock (start, then lock). The second one is
    # the way back when the shell dies while the screen is locked. Left as
    # plain `caelestia shell -d` under UWSM, both would start a second shell
    # outside the unit, so both go through caelestia-shell-up.
    #
    # It kills the shell in two places too: CTRL+SUPER+SHIFT+R (kill only) and
    # the first half of CTRL+SUPER+ALT+R. Upstream's `qs -c caelestia kill`
    # never worked on NixOS, in either session. `-c` looks for a config
    # directory named caelestia under ~/.config/quickshell, but the shell runs
    # from its store path, so qs reports 'Could not find "caelestia" config
    # directory' and kills nothing. That made the kill bind a no-op, and the
    # restart bind a no-op start of a shell that was still running.
    # caelestia-shell-kill picks the right way for each session.
    #
    # --replace-fail replaces every occurrence and fails only if there are none.
    substituteInPlace $out/hypr/hyprland/keybinds.lua \
      --replace-fail 'caelestia shell -d' '${shellUp}/bin/caelestia-shell-up' \
      --replace-fail 'qs -c caelestia kill' '${shellKill}/bin/caelestia-shell-kill'

    # QT_QPA_PLATFORMTHEME=qtengine — qtengine is AUR-only, and the rest of
    # caelestia's Qt support writes to ~/.config/qtengine/ where nothing on
    # NixOS reads it. `kde` is plasma-integration, which reads kdeglobals
    # instead and re-themes running apps on a D-Bus signal. See ../home/qt.nix
    # for the daemon that drives it; this line is the half that has to live in
    # the dots, because Hyprland's own env block is what the session inherits.
    substituteInPlace $out/hypr/hyprland/env.lua \
      --replace-fail '"QT_QPA_PLATFORMTHEME", "qtengine"' '"QT_QPA_PLATFORMTHEME", "kde"'

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

    # Night light off. execs.lua starts gammastep on every login, so the whole
    # session goes amber after sunset. Only the autostart is dropped —
    # gammastep stays in home.packages below, so running it by hand still
    # works, and the geoclue agent on the line above stays with it: that is
    # the location provider gammastep needs if it is ever wanted again.
    substituteInPlace $out/hypr/hyprland/execs.lua \
      --replace-fail $'\n    hl.exec_cmd("sleep 1 && gammastep")' "" \
      --replace-fail '-- Location provider and night light' '-- Location provider'
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

  # The `qs` CLI, for inspecting the running shell by hand (`qs list --all`,
  # `qs ipc`). The kill/restart keybinds no longer use it; see
  # caelestia-shell-kill. The shell derivation bundles quickshell inside its
  # own wrapper, so nothing puts `qs` on PATH.
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
    }).withModules [ pkgs.qt6.qtimageformats m3shapes ];

  # Material shapes QML module (bar workspace indicators, since v2.4.0).
  # Upstream split it into its own flake; nix/default.nix now takes the built
  # package and adds it to quickshell's withModules, rather than the raw source
  # CMake used to FetchContent. Passing the source instead fails evaluation
  # with "Dependency is not of a valid type" in quickshell-wrapped.
  m3shapes =
    inputs.caelestia-shell.inputs.m3shapes.packages.${pkgs.stdenv.hostPlatform.system}.default;
  # ── The version string nexus → About reports.
  #
  # Upstream's nix/default.nix hardcodes `version = "1.0.0"` and hands it to
  # CMake as -DVERSION, which becomes CAELESTIA_VERSION, which is exactly what
  # AboutPage.qml prints via CUtils::version(). It is a placeholder they never
  # wired to the release tag, so every Nix build of the shell claims 1.0.0 no
  # matter which version it actually is — the About page was not reporting a
  # failed update.
  #
  # It has to be supplied here rather than left out: CMakeLists.txt only falls
  # back to `git describe --tags` when VERSION is undefined, and the store copy
  # has no .git, so an undefined VERSION is a FATAL_ERROR rather than a guess.
  #
  # Read out of flake.lock instead of written literally, so it cannot drift from
  # the tag in flake.nix on the next bump. Falls back to upstream's own
  # placeholder if the input is ever pointed at a branch instead of a tag —
  # CMake's project(VERSION) rejects anything non-numeric, so "main" would be a
  # build failure rather than a cosmetic wrong answer.
  shellRef =
    (builtins.fromJSON (builtins.readFile ../flake.lock)).nodes.caelestia-shell.original.ref
      or "";
  shellVersion =
    if builtins.match "v?[0-9]+(\\.[0-9]+)*" shellRef != null
    then lib.removePrefix "v" shellRef
    else "1.0.0";

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

    # See shellVersion above — replaces upstream's hardcoded placeholder with
    # the tag this is actually built from. --replace-fail so an upstream change
    # to that line surfaces here instead of silently restoring "1.0.0".
    substituteInPlace $out/nix/default.nix \
      --replace-fail 'version = "1.0.0";' 'version = "${shellVersion}";'

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

    # ── A closed dropdown still swallows clicks on the row beneath it.
    #
    # components/controls/Menu.qml hides a closed menu with opacity 0 plus
    # `transform: Scale { yScale: 0.1 }`. Opacity and scale change how an item
    # draws, never whether it hit-tests, so the box stays in the input path at
    # a tenth of its height, hanging directly below its own chevron.
    #
    # The residue scales with the entry count, which is why this looks like a
    # per-monitor bug rather than a component one. On this laptop:
    #
    #   eDP-1     1 resolution   ~50px box  -> ~5px  residue, hits nothing
    #   HDMI-A-1  16 resolutions ~770px box -> ~77px residue, covers one row
    #
    # A SelectRow is ~66px, so on HDMI the Resolution menu lands exactly on
    # Refresh rate and nothing else: that row's chevron is dead and the row
    # does not even highlight on hover, while Scale and Transform below it are
    # untouched. Confirmed by hover test on Hyprland 0.56.0.
    #
    # `visible` is the fix rather than `enabled`, because the root MouseArea
    # already carries `enabled: expanded` and that plainly is not keeping the
    # subtree out of hit testing. visible:false removes it from both rendering
    # and input, unconditionally.
    #
    # Keyed on opacity, not on `expanded`, so the close animation still plays
    # out: opacity is animated by a Behavior, so this only goes false on the
    # frame it actually reaches 0.
    #
    # Not scoped to the Display page on purpose — every dropdown in the shell
    # with enough entries has this, the Display page just happens to be where
    # a 16-entry menu sits directly above another control.
    substituteInPlace $out/components/controls/Menu.qml \
      --replace-fail $'    enabled: expanded\n    hoverEnabled: expanded\n' \
        $'    enabled: expanded\n    hoverEnabled: expanded\n    visible: opacity > 0\n'

    # ── Name the machine, not the compositor.
    #
    # SysInfo.wm (utils/SysInfo.qml) is nothing but XDG_CURRENT_DESKTOP, so
    # every surface that prints it just says "Hyprland" — which the bar already
    # makes obvious. Both of its consumers are replaced with a constant here.
    # Neither has a Config binding, so patching is the only way in.
    #
    # 1. modules/dashboard/dash/User.qml — the speech bubble beside the avatar,
    #    labelled `SysInfo.wm + "..."`. Those trailing dots are a literal string
    #    upstream appends for the speech-bubble look, not Text.ElideRight
    #    truncating a longer name, so the whole expression goes.
    #
    # 2. modules/lock/Fetch.qml — the "WM  :" line of the neofetch-style block
    #    on the lock screen. Only the interpolation is replaced; the label and
    #    its two-space padding stay, because the surrounding lines (OS/USER/UP/
    #    BATT) are column-aligned by that padding in a MonoText.
    #
    # --replace-fail on both, so an upstream rewrite of either surfaces here
    # instead of silently restoring "Hyprland".
    substituteInPlace $out/modules/dashboard/dash/User.qml \
      --replace-fail 'text: SysInfo.wm + "..."' 'text: "Noouoops"'

    substituteInPlace $out/modules/lock/Fetch.qml \
      --replace-fail 'WM  : ''${SysInfo.wm}' 'WM  : Hyprland'

    # ── Put the screenshot on the clipboard without a trip through swappy.
    #
    # modules/areapicker/Picker.qml save() writes the selection to a temp PNG,
    # then forks on loader.clipboardOnly: true wl-copies it and notifies, false
    # hands the file to `swappy -f` for annotation. The two are exclusive
    # upstream, so the SUPER+SHIFT+S path (screenshotFreeze -> clipboardOnly
    # false) leaves the clipboard untouched and swappy's own Copy button /
    # CTRL+C is the only way to get the image out — an extra deliberate step
    # for the common case, which is paste-it-somewhere-immediately.
    #
    # This adds the wl-copy to the swappy branch rather than switching the
    # keybind to the existing caelestia:screenshotFreezeClip global, because
    # that global suppresses swappy entirely and annotation is worth keeping.
    # Both now run: the raw crop lands on the clipboard the moment the
    # selection is released, and swappy still opens on top of it.
    #
    # Note this copies the RAW crop, not the annotated result — swappy re-copies
    # over it if you annotate and press CTRL+C, which is the same key that
    # already worked. Copying swappy's output instead would mean `-o -` piped
    # to wl-copy, which defers the clipboard write until swappy exits and also
    # fires on cancel; immediate-and-raw is the better default here.
    #
    # Applies to every entry point (Print, SUPER+SHIFT+S, SUPER+SHIFT+ALT+S,
    # `caelestia screenshot`) — they all funnel through this one save().
    #
    # The wl-copy line is copied verbatim from the clipboardOnly branch above
    # it, sh -c redirect included: execDetached takes an argv, not a shell
    # line, so the `<` needs a real shell to mean anything.
    #
    # --replace-fail so an upstream rewrite of the swappy invocation surfaces
    # here instead of silently dropping the auto-copy.
    substituteInPlace $out/modules/areapicker/Picker.qml \
      --replace-fail $'Quickshell.execDetached(["swappy", "-f", path]);' \
        $'Quickshell.execDetached(["sh", "-c", "wl-copy --type image/png < " + path]);\n                Quickshell.execDetached(["swappy", "-f", path]);'
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
    inherit m3shapes;
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

  # ── SUPER+B → pwvucontrol, as a show/hide toggle.
  #
  # pwvucontrol is GTK4 without single-instance handling, so a plain
  # `exec_cmd pwvucontrol` bind stacks a fresh window on every press. This
  # does the three-state toggle instead: launch if absent, focus if open but
  # unfocused, close if it is the active window.
  #
  # The class is matched case-insensitively on the substring rather than
  # pinned to the literal `com.saivert.pwvucontrol` app-id, so the bind keeps
  # working if upstream renames it (or if you swap the binary for pavucontrol
  # below — its class is org.pulseaudio.pavucontrol, which does not match, so
  # change `class` too if you do).
  volumeControlToggle = pkgs.writeShellScriptBin "volume-control-toggle" ''
    jq=${pkgs.jq}/bin/jq
    addr=$(hyprctl clients -j | $jq -r 'first(.[] | select(.class | test("pwvucontrol"; "i")) | .address) // empty')

    if [ -z "$addr" ]; then
      exec ${pkgs.pwvucontrol}/bin/pwvucontrol
    elif [ "$addr" = "$(hyprctl activewindow -j | $jq -r '.address // empty')" ]; then
      hyprctl dispatch closewindow "address:$addr"
    else
      hyprctl dispatch focuswindow "address:$addr"
    fi
  '';

  # ── SUPER+SHIFT+K → on-screen keyboard (wvkbd), show/hide toggle.
  #
  # wvkbd, not onboard, because onboard is an X11 app that types through
  # XTEST: under Hyprland its keystrokes only reach XWayland
  # clients and vanish in foot, Zen, or a Wayland-native VS Code. wvkbd is a
  # layer-shell surface driving zwp_virtual_keyboard_v1, so it sits above every
  # window, never takes keyboard focus away from the app you are typing into,
  # and its keys land everywhere.
  #
  # The trade-off, accepted deliberately: layer-shell surfaces are anchored by
  # the protocol. `wvkbd --help` exposes height, colours and font but no
  # position, and Hyprland has no layerrule for repositioning a layer — so this
  # cannot be dragged around the way a floating window can. Height only.
  #
  # Exclusive zone left on (i.e. no --non-exclusive): the compositor shrinks
  # the tiled area while the keyboard is up, so it never covers the very text
  # field you are typing into. Add --non-exclusive below if you would rather it
  # overlap windows and leave layout untouched.
  #
  # pkill exits 1 when nothing matched, which doubles as the "not started yet"
  # branch — first press launches it visible, every press after that flips
  # visibility via SIGRTMIN. Nothing runs at login.
  oskToggle = pkgs.writeShellScriptBin "osk-toggle" ''
    if ${pkgs.procps}/bin/pkill -RTMIN -x wvkbd-mobintl; then
      exit 0
    fi
    exec ${wvkbdBelowShell}/bin/wvkbd-mobintl -H 300 --fn "Rubik 16"
  '';

  # ── Keep the OSK underneath the shell's panels.
  #
  # `hyprctl layers` showed caelestia's surfaces on level 2 (top) and wvkbd on
  # level 3 (overlay), so the keyboard covered the bar whenever a panel expanded
  # on hover. Hyprland cannot fix this from config: HL.LayerRuleSpec (see
  # share/hypr/stubs/hl.meta.lua) offers `order`, which only sorts layers
  # *within* one level, and no rule at all for moving a surface between levels.
  #
  # So the level has to change client-side. wvkbd hardcodes the layer at
  # main.c:61 with no flag to override it — a one-token substitution, and the
  # constant appears exactly once in the source, so --replace-fail will catch
  # any upstream rename on the next bump rather than silently no-op.
  #
  # Landing on level 2 alongside caelestia's own surfaces, the ordering is then
  # decided by `order` — see the layer_rule in hypr-user.lua below.
  wvkbdBelowShell = pkgs.wvkbd.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace main.c \
        --replace-fail ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY ZWLR_LAYER_SHELL_V1_LAYER_TOP
    '';
  });

  # Read by both hypr-vars.lua (-> env.lua's XCURSOR_SIZE and the execs.lua
  # setcursor/gsettings calls) and uwsm/env-hyprland, so the two can't drift.
  cursorSize = 24;

  # ── UWSM-or-not switches for the dots (see the execs.lua/keybinds.lua
  # patches in `dots`).
  #
  # CAELESTIA_UWSM is exported from uwsm/env-hyprland below. uwsm sources
  # that file only for a UWSM-managed Hyprland session, puts the result in the
  # systemd activation environment the compositor unit starts with, and
  # unsets it again on `uwsm stop`. So Hyprland and everything it spawns see
  # it exactly when running under UWSM. The plain "Hyprland" session is
  # started by sddm-helper and never inherits it. It is our own variable
  # rather than one of uwsm's internal UWSM_* names, which could change
  # between uwsm releases.

  # Run the command only outside UWSM, where no systemd unit covers it.
  unlessUwsm = pkgs.writeShellScriptBin "unless-uwsm" ''
    [ -n "''${CAELESTIA_UWSM:-}" ] && exit 0
    exec "$@"
  '';

  # Start the shell the way this session runs it: the caelestia user unit
  # under UWSM, `caelestia shell -d` otherwise.
  #
  # reset-failed first because kbRestoreLock exists for a shell that has
  # just crashed. If it crashed repeatedly, the unit may have hit its start
  # limit, and a plain `start` would refuse. --no-block because execs.lua
  # calls this during hyprland.start, before graphical-session.target
  # (which the unit is ordered after) can be reached. A blocking start would
  # just leave a systemctl process waiting.
  shellUp = pkgs.writeShellScriptBin "caelestia-shell-up" ''
    if [ -n "''${CAELESTIA_UWSM:-}" ]; then
      systemctl --user reset-failed caelestia.service 2>/dev/null
      exec systemctl --user start --no-block caelestia.service
    fi
    exec caelestia shell -d
  '';

  # Stop the shell, the counterpart of caelestia-shell-up.
  #
  # Under UWSM this is `systemctl --user stop`, so the unit is actually
  # inactive afterwards. Restart=on-failure would not bring back a shell that
  # was stopped this way. `stop` blocks until the process is gone (the unit's
  # TimeoutStopSec is 5s), so CTRL+SUPER+ALT+R's `; sleep .1;
  # caelestia-shell-up` starts a fresh one rather than racing the old one.
  # KillMode=process keeps apps launched from the shell alive through it.
  #
  # Otherwise `caelestia shell -k`, which runs `caelestia-shell kill`. That
  # wrapper passes the shell's own store path to qs, which is what
  # `qs -c caelestia` gets wrong here.
  shellKill = pkgs.writeShellScriptBin "caelestia-shell-kill" ''
    if [ -n "''${CAELESTIA_UWSM:-}" ]; then
      exec systemctl --user stop caelestia.service
    fi
    exec caelestia shell -k
  '';
in {
  imports = [ inputs.caelestia-shell.homeManagerModules.default ];

  # ── The shell (bar, launcher, notifications, lock screen, OSDs).
  #
  # Runs as the `caelestia` user unit under UWSM (WantedBy
  # wayland.systemd.target, i.e. graphical-session.target), which gets it
  # Restart=on-failure and `journalctl --user -u caelestia`. The plain
  # "Hyprland" fallback session never reaches that target, so there execs.lua
  # starts it as before. The unless-uwsm / caelestia-shell-up patches in the
  # let block keep the two paths from both firing. Two shells would fight
  # over the same layer surfaces.
  #
  # Needs the UWSM env files (uwsm/env*) below: a unit gets the systemd
  # activation environment, not Hyprland's hl.env, so without them the shell
  # would lose QT_QPA_PLATFORMTHEME=kde and the cursor variables.
  programs.caelestia = {
    enable = true;
    cli.enable = true;
    systemd.enable = true;

    # The nexus Display page (see shellSrc above). Everything else about this
    # package is upstream's own build.
    package = caelestiaShell;
  };

  # KillMode=process: stop or restart only the shell itself.
  #
  # Upstream's unit leaves KillMode at the default, control-group. Everything
  # the shell launches (apps from the launcher, the session menu, the
  # dashboard) is forked from it and lives in its cgroup. So a crash
  # restart, `systemctl --user restart caelestia`, or home-manager's
  # sd-switch restarting a changed unit would kill every one of those apps
  # along with it. Under execs.lua they sat in the compositor's cgroup, where
  # a shell restart never touched them. This keeps that behaviour. Apps still
  # end at logout, because they lose the Wayland display.
  systemd.user.services.caelestia.Service.KillMode = "process";

  # ── Polkit agent and clipboard history as units (UWSM only; the plain
  # session keeps the execs.lua lines, see the let block).
  #
  # The polkit agent is the libexec binary, so installing the module adds no
  # XDG autostart entry (see modules/hyprland-desktop.nix). Upstream's unit
  # has no Restart=; a dead agent means silently missing auth prompts, so add
  # one.
  services.polkit-gnome.enable = true;
  systemd.user.services.polkit-gnome.Service.Restart = "on-failure";

  # Two units, cliphist and cliphist-images, in place of execs.lua's two
  # `wl-paste --type text|image --watch cliphist store` lines.
  #
  # Two small differences from those lines:
  # - The HM text unit watches without `--type text`. An image copy can then
  #   reach both units; cliphist's dedupe search drops the second copy.
  # - extraOptions is emptied. The module defaults to -max-dedupe-search 10
  #   -max-items 500, while the execs.lua lines use cliphist's built-in 100 /
  #   750. The plain session and the UWSM session share one history
  #   database, so they should agree on how much it keeps.
  services.cliphist = {
    enable = true;
    allowImages = true;
    extraOptions = [ ];
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
    # Our own fastfetch config, no longer upstream's (see home/fastfetch/).
    "fastfetch/config.jsonc".source = ./fastfetch/config.jsonc;

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
          cursorSize   = ${toString cursorSize},

          -- rules.lua widens gaps_out to singleWindowGapsOut on a normal
          -- workspace holding one window (w[tv1]s[false] / f[1]s[false]), so a
          -- lone window sat further from the bar than on special workspaces
          -- or with 2+ windows. Match windowGapsOut so every case looks alike.
          singleWindowGapsOut = 10,

          -- ── iGPU relief (Aug 2026).
          --
          -- The Alder Lake-P GT1 composites both 1080p high-refresh outputs
          -- by design (PRIME offload — the RTX 3050 only wakes for
          -- nvidia-offload clients) and measured ~75% busy at its 1200MHz
          -- ceiling at idle desktop. Three upstream defaults cause it:
          --
          --   windowOpacity = 0.95 — rules.lua applies `opacity 0.95 override`
          --     to EVERY non-fullscreen window, so every window counts as
          --     translucent and Hyprland blurs behind all of them, every
          --     frame. 1.0 makes windows opaque; blur is then only sampled
          --     where something is genuinely translucent (bar, popups, foot
          --     with its own alpha=0.78). The single biggest win.
          --   blur size=8/passes=2 — blur re-renders per pass; 4/1 quarters
          --     the cost with a barely visible difference.
          --   shadows (range 15, render_power 4) — a per-window fragment
          --     cost on every frame at 180Hz, for a barely-there 6%-alpha
          --     shadow. Off.
          --
          -- Rounding stays — it's a cheap one-time shader term. Animations
          -- stay — they're the shell's identity and only cost while moving.
          windowOpacity = 1.0,
          blurSize      = 4,
          blurPasses    = 1,
          shadowEnabled = false,

          -- Blur stays ON, and the paragraph above is why: with windowOpacity
          -- at 1.0 the only translucent surfaces left are the bar, popups and
          -- foot, so blur is sampled over a few hundred pixels rather than the
          -- whole screen. It is the cheap half of the tuning, not a casualty
          -- of it.
          --
          -- Pinned explicitly even though upstream already defaults it to true
          -- (dots hypr/variables.lua:23), because it did not stay true: a
          -- HyprMod save had written decoration.blur.enabled = false into
          -- ~/.config/hypr/hyprland-gui.lua, which hypr-user.lua dofiles LAST
          -- and which therefore won. Qt menus (breezerc MenuOpacity, see
          -- ./qt.nix) were then simply transparent with nothing behind them.
          --
          -- This line does NOT defend against that file — load order still
          -- beats it. It states the intent so the next person diffing a
          -- washed-out session has something to compare against.
          blurEnabled   = true,
      }
    '';

    # ── Session environment under UWSM.
    #
    # env.lua's hl.env only reaches processes Hyprland itself spawns. Under
    # UWSM, everything the user manager starts — portals, D-Bus-activated apps,
    # user units — gets the systemd activation environment instead, which uwsm
    # builds by sourcing these files (as POSIX sh) before the compositor starts.
    # A variable left only in env.lua shows up as theming that is right in some
    # apps and wrong in others.
    #
    # `env` is loaded for every UWSM session, `env-hyprland` only when
    # "Hyprland" is in the session's desktop names (lowercased by uwsm).
    #
    # Values mirror the dots' env.lua exactly, including upstream's
    # SDL_VIDEODRIVER list and the `kde` platform theme patched in above —
    # two different values would make an app's theme depend on who launched
    # it. env.lua is left as is: same values, set twice, no harm.
    #
    # XDG_CURRENT_DESKTOP / XDG_SESSION_TYPE / XDG_SESSION_DESKTOP are not
    # here on purpose; uwsm derives them from the session entry.
    #
    # Only read by uwsm, so the plain "Hyprland" fallback session is unaffected.
    "uwsm/env".text = ''
      export QT_QPA_PLATFORMTHEME=kde
      export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
      export QT_AUTO_SCREEN_SCALE_FACTOR=1
      export GDK_BACKEND=wayland,x11
      export QT_QPA_PLATFORM='wayland;xcb'
      export SDL_VIDEODRIVER=wayland,x11,windows
      export CLUTTER_BACKEND=wayland
      export ELECTRON_OZONE_PLATFORM_HINT=auto
      export _JAVA_AWT_WM_NONREPARENTING=1
    '';

    # uwsm's hyprland plugin already marks XCURSOR_THEME/XCURSOR_SIZE for
    # export on finalize, so these reach the user manager too.
    #
    # CAELESTIA_UWSM is the "running under UWSM" marker the execs.lua and
    # keybinds.lua patches key on (unless-uwsm, caelestia-shell-up).
    "uwsm/env-hyprland".text = ''
      export XCURSOR_THEME=${lib.escapeShellArg config.themes.activeCursor}
      export XCURSOR_SIZE=${toString cursorSize}
      export CAELESTIA_UWSM=1
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

      -- Rebind SUPER+V: pick from the clipboard list AND paste in one step.
      --
      -- Upstream (keybinds.lua:174) runs `caelestia clipboard`, which only
      -- wl-copies the picked entry — you still need CTRL+V afterwards. This
      -- appends a synthesised CTRL+V via ydotool (daemon + uinput group
      -- already set up in modules/hyprland-desktop.nix), so the entry lands
      -- directly in the focused input. The && chain keeps every upstream
      -- behaviour: pkill-fuzzel toggle-close short-circuits the ||, and a
      -- cancelled picker (Esc) exits non-zero so nothing is pasted. wl-copy
      -- forks only after buffering the data, and the sleep gives fuzzel time
      -- to close and Hyprland to return focus to the previous window.
      --
      -- Caveat: the keystroke is CTRL+V, which terminals don't treat as
      -- paste (foot wants CTRL+SHIFT+V) — in a terminal it falls back to
      -- the old copy-only behaviour and you paste manually.
      hl.unbind("SUPER + V")
      hl.bind(
          "SUPER + V",
          hl.dsp.exec_cmd("pkill fuzzel || (caelestia clipboard && sleep 0.2 && ydotool key 29:1 47:1 47:0 29:0)")
      )

      hl.bind("SUPER + SHIFT + P", hl.dsp.global("caelestia:nexus"))
      hl.bind("SUPER + CTRL + up", hl.dsp.exec_cmd("brightnessctl -d acer_ec::kbd_backlight set +10%"), { repeating = true })
      hl.bind("SUPER + CTRL + down", hl.dsp.exec_cmd("brightnessctl -d acer_ec::kbd_backlight set 10%-"), { repeating = true })
      hl.bind("SUPER + CTRL + K", hl.dsp.exec_cmd("acer-kbd-toggle"))

      -- SUPER+B → pwvucontrol (PipeWire volume control), show/hide toggle.
      --
      -- B was completely free: `hyprctl binds` listed no entry for the key at
      -- any modmask, and upstream keybinds.lua never uses it — so no unbind is
      -- needed here, unlike SUPER+W/SUPER+V above. Upstream's own audio bind
      -- (CTRL+ALT+V, vars.audioSettings → pavucontrol) is untouched and still
      -- works; this is the faster second door.
      hl.bind("SUPER + B", hl.dsp.exec_cmd("volume-control-toggle"))

      -- SUPER+SHIFT+K → on-screen keyboard toggle (wvkbd; see the let block).
      --
      -- `hyprctl binds` showed SUPER+SHIFT (modmask 65) free on K, and the
      -- SHIFT plane is where caelestia already parks panel/tool invocations,
      -- same reasoning as SUPER+SHIFT+P above. Keeps the K family together:
      -- SUPER+K showall panels (upstream), SUPER+CTRL+K keyboard backlight,
      -- SUPER+SHIFT+K on-screen keyboard.
      hl.bind("SUPER + SHIFT + K", hl.dsp.exec_cmd("osk-toggle"))

      -- SUPER+SHIFT+Z → Zen browser, SUPER+SHIFT+V → VS Code.
      --
      -- Both combos were completely free: `hyprctl binds` listed nothing on Z
      -- or V at modmask 65, and upstream keybinds.lua never uses either — so no
      -- unbind is needed, unlike SUPER+W/SUPER+V above. Note this does NOT
      -- collide with the SUPER+V clipboard bind: Hyprland matches modmasks
      -- exactly, so 64 (SUPER) and 65 (SUPER+SHIFT) are separate binds.
      --
      -- Plain exec, not the launch/focus/close toggle that SUPER+B and
      -- SUPER+SHIFT+K use. Those drive single-window utility panels where
      -- closing on a third press is the point; an editor or browser must never
      -- be closed by a keybind. Both apps handle re-invocation themselves —
      -- Zen remotes into the running instance (Firefox-derived), and `code`
      -- hands off to the existing window over its IPC socket.
      --
      -- Zen is the user flatpak app.zen_browser.zen (see home/app-limits.nix
      -- for its memory cap), launched via `flatpak run` rather than the
      -- ~/.local/share/flatpak/exports/bin wrapper so the bind does not depend
      -- on that export dir being in the compositor's inherited PATH.
      -- `code` comes from modules/package.nix, on the system profile. It is
      -- started in its own app-code-* scope so the memory cap in
      -- home/app-limits.nix applies; a bare exec would land in no scope.
      hl.bind("SUPER + SHIFT + Z", hl.dsp.exec_cmd("flatpak run app.zen_browser.zen"))
      hl.bind("SUPER + SHIFT + V", hl.dsp.exec_cmd("systemd-run --user --scope --collect --slice=app.slice --unit=app-code-$(date +%s%N) code"))

      -- SUPER+SHIFT+O → Obsidian (modules/package.nix). Free combo too:
      -- nothing in upstream keybinds.lua or `hyprctl binds` uses O. Obsidian
      -- is Electron and focuses its running window when invoked again.
      hl.bind("SUPER + SHIFT + O", hl.dsp.exec_cmd("obsidian"))

      -- Render the OSK beneath the shell's panels. The wvkbd override in the
      -- Nix let block moves it from the overlay level down to `top`, where
      -- caelestia's own surfaces live; this decides who wins inside that level.
      -- Higher order = closer to the front, default 0, so a negative value puts
      -- the keyboard behind caelestia-drawers and the bar can expand on hover
      -- without being covered. If it somehow lands the wrong way round after a
      -- Hyprland bump, flip the sign here — nothing else depends on it.
      hl.layer_rule({ match = { namespace = "wvkbd" }, order = -1 })

      -- ── Kill the Hyprland splash text.
      --
      -- Hyprland draws one random line from its built-in NSplashes::SPLASHES
      -- table onto its own background layer — the contributor credits,
      -- "Thanks ThatOneCalculator!" / "Thanks fufexan!" and friends. It is
      -- visible in the gap between the compositor coming up and caelestia
      -- painting the wallpaper over the top of it, which is why it only ever
      -- flashes just after logging in from SDDM.
      --
      -- upstream's hyprland/misc.lua already sets disable_hyprland_logo, but
      -- the logo and the splash TEXT are two separate options and only the
      -- first was covered — hence the leftover line at the bottom of the
      -- screen. This is the other half.
      --
      -- Set from here rather than by patching misc.lua: hypr-user.lua runs
      -- last and hl.config merges per key, so the rest of upstream's misc
      -- block (background_color, the dpms keys, …) is left alone.
      --
      -- Note for anyone changing this at runtime: `hyprctl keyword` is
      -- rejected under the Lua parser (see the monitor section below), so the
      -- live equivalent is
      --   hyprctl eval 'hl.config({ misc = { disable_splash_rendering = true } })'
      hl.config({ misc = { disable_splash_rendering = true } })

      -- ── NumLock starts OFF, which is what puts the numpad in pointer mode.
      --
      -- modules/mousekeys.nix reads NumLock as an LED and claims the numpad
      -- only while that LED is dark, so this one line is what decides whether
      -- mousekeys is live the moment the session comes up. Upstream's
      -- input.lua:6 already sets false and so does Hyprland itself, which is
      -- precisely the problem: nothing here would notice a caelestia bump
      -- flipping it, and the symptom would be a numpad that silently stopped
      -- moving the pointer. Pinned here, where the comment can say why.
      --
      -- hl.config merges per key, so upstream's kb_layout / repeat_rate /
      -- touchpad block in that same `input` table is left alone.
      --
      -- This governs the SESSION only. SDDM turns NumLock on for the greeter
      -- (autoNumlock, modules/sddm.nix), so the numpad still types digits at
      -- the password prompt and only becomes a pointer once Hyprland is up.
      hl.config({ input = { numlock_by_default = false } })

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

      -- ── HyprMod's managed file.
      --
      -- The GTK settings GUI (see home.packages below) keeps every edit it
      -- makes in ~/.config/hypr/hyprland-gui.lua and touches nothing else.
      -- Loaded here, at the very end of the very last file Hyprland reads,
      -- so its overrides win over upstream, over the binds above, and over
      -- monitors.lua — which is the point of a live tweaking tool.
      --
      -- dofile, NOT the loadfile+pcall used for monitors.lua above, and the
      -- difference is load-bearing. HyprMod's needs_setup() walks the
      -- config's dofile/require chain looking for its own file; a loadfile
      -- chunk executes but leaves no node in that walk. Miss it and the app
      -- offers, on every launch, to append `require("hyprland-gui")` to
      -- hyprland.lua itself — via an atomic write (tempfile + os.replace)
      -- that would succeed, because `recursive = true` makes ~/.config/hypr
      -- a real writable directory, and would REPLACE the home-manager store
      -- symlink with a plain file. The next `nixos-rebuild switch` then
      -- aborts with "existing file is in the way". Never accept that
      -- dialog; this line is what stops it being offered.
      --
      -- io.open("a") first because dofile raises on a missing file, and the
      -- file genuinely does not exist until the GUI has saved something.
      -- pcall for the same reason monitors.lua is loaded defensively: a
      -- half-written GUI save must not take the whole config, and with it
      -- the session, down.
      local guiFile = os.getenv("HOME") .. "/.config/hypr/hyprland-gui.lua"
      local guiStub = io.open(guiFile, "a")
      if guiStub then guiStub:close() end
      local guiOk, guiErr = pcall(dofile, guiFile)
      if not guiOk then
          print("[hypr-user] hyprland-gui.lua failed to apply: " .. tostring(guiErr))
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
    pwvucontrol # SUPER+B via volume-control-toggle (let block above)
    volumeControlToggle
    wvkbdBelowShell # SUPER+SHIFT+K via osk-toggle (let block above)
    oskToggle
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

    # ── HyprMod — a settings GUI for the compositor itself.
    #
    # From the flake input (not in nixpkgs). Reads caelestia's whole
    # require() tree without complaint and applies changes live over
    # `hyprctl eval` — it already knows `keyword` is rejected by the Lua
    # parser, the same wall documented in the monitor section of
    # hypr-user.lua above. Its edits land in hyprland-gui.lua, which that
    # file dofiles last; nothing here is written by home-manager.
    #
    # Do NOT trust its Decoration page. Its reader re-executes variables.lua
    # on every require() instead of caching the module the way Hyprland
    # does, so the hypr-vars.lua merge hyprland.lua performs (it mutates the
    # cached table in place) is invisible to it. It opens showing upstream's
    # blur size 8 / passes 2 / shadows on, not the 4 / 1 / off set in
    # hypr-vars.lua above — same story for cursorTheme, which it reads as
    # upstream's sweet-cursors. It only writes what you actually edit, but
    # anything saved from that page lands in a file that loads last and
    # silently undoes the iGPU relief tuning.
    inputs.hyprmod.packages.${pkgs.stdenv.hostPlatform.system}.default

    cliphist
    wl-clipboard
    trash-cli # `trash-empty 30` on session start
    gammastep # night light — kept for manual use only, the execs.lua
              # autostart is patched out in the dots derivation above
    geoclue2-with-demo-agent # location provider for gammastep
    gnome-keyring
    bluez # mpris-proxy, forwards BT media keys to MPRIS
    wireplumber # wpctl, volume keybinds
    glib # gsettings, used by execs.lua for cursor

    # Qt theming lives in ../home/qt.nix — plasma-integration + Breeze,
    # following the dark/light mode. qt6ct and darkly used to be here as the
    # stand-in for env.lua's qtengine; both are gone with it. Nothing ever
    # wrote qt6ct.conf, so it was pinned to a hand-set July 2026 palette, and
    # darkly was a style that config never actually selected.

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

  # ── Idle behaviour (dim / lock / suspend), merged into shell.json.
  #
  # shell.json is one of the mutable configs: the shell auto-saves it whenever
  # a nexus setting changes (RootConfig::saveToFile), so it CANNOT be a
  # home-manager store symlink (that read-only trap is why mutableConfigs
  # exists). Instead this activation merges our `general.idle` object into
  # the live file at rebuild time; the shell's QFileSystemWatcher picks the
  # change up without a restart, and its own saves preserve these keys
  # (they're known properties — once loaded they're written back as-is).
  #
  # Why the shell and not logind/hypridle: IdleMonitors.qml already keys idle
  # actions off UPower's onBattery, which is exactly the AC/battery split
  # requested here. `inhibitWhenCharging` disables every idle monitor while
  # on AC, so AC gets no dim, no lock and no suspend. On battery:
  #   5 min  — dim the panel to 0 (brightnessctl -s/-r save+restore, so the
  #            previous brightness comes back on activity)
  #   30 min — lock
  #   60 min — `systemctl suspend` (lockBeforeSleep locks the session first;
  #            logind's IdleAction stays "ignore", modules/power.nix, so
  #            nothing double-sleeps)
  home.activation.caelestiaShellIdle =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      shellJson="${config.xdg.configHome}/caelestia/shell.json"
      run mkdir -p "$(dirname "$shellJson")"
      [ -s "$shellJson" ] || echo '{}' > "$shellJson"
      ${pkgs.jq}/bin/jq --argjson idle '${builtins.toJSON {
        lockBeforeSleep = true;
        inhibitWhenAudio = true;
        inhibitWhenCharging = true;
        timeouts = [
          {
            timeout = 300;
            idleAction = [ "brightnessctl" "-s" "set" "0" ];
            returnAction = [ "brightnessctl" "-r" ];
          }
          {
            timeout = 1800;
            idleAction = "lock";
          }
          {
            timeout = 3600;
            idleAction = [ "systemctl" "suspend" ];
          }
        ];
      }}' '.general.idle = $idle' "$shellJson" > "$shellJson.tmp" \
        && mv "$shellJson.tmp" "$shellJson"
    '';

  # ── Logout through UWSM, merged into shell.json the same way.
  #
  # The session menu's default logout is the built-in `logout` alias, which is
  # logind Session.Terminate (SessionManager::logout in the shell's plugin) —
  # exactly `loginctl terminate-session`. That kills every process in the
  # session scope, sddm-helper included. SDDM reads the SIGTERM'd helper as a
  # crash ("Auth: sddm-helper ... crashed (exit code 1)") and never brings the
  # greeter back: the screen sits on a bare VT with a blinking cursor and no
  # input (2026-09-16; ended in a forced power-off and a dirty /mnt/doc).
  #
  # `uwsm stop` is UWSM's own exit path instead: it stops the compositor unit
  # and the session targets, uwsm's process under sddm-helper then returns
  # normally, and SDDM restarts the greeter the way it does after any clean
  # logout. "uwsm" is not one of the shell's aliases, so SessionManager.exec
  # falls through to Quickshell.execDetached with this argv.
  #
  # Trade-off: in the plain "Hyprland" fallback session there is no UWSM
  # session to stop, so the menu's logout does nothing there. A no-op beats a
  # hung display manager.
  home.activation.caelestiaShellLogout =
    lib.hm.dag.entryAfter [ "caelestiaShellIdle" ] ''
      shellJson="${config.xdg.configHome}/caelestia/shell.json"
      ${pkgs.jq}/bin/jq --argjson logout '${builtins.toJSON [ "uwsm" "stop" ]}' \
        '.session.commands.logout = $logout' "$shellJson" > "$shellJson.tmp" \
        && mv "$shellJson.tmp" "$shellJson"
    '';

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
