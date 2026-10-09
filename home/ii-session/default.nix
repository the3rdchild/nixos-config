{
  config,
  inputs,
  pkgs,
  lib,
  ...
}: let
  # ── The session: illogical-impulse + the end4-pC fork.
  #
  # This file owns a config root of its own, and the session is launched with
  # XDG_CONFIG_HOME pointed at it:
  #
  #   ~/.config/      home-manager's own output, for shells and apps started
  #                   outside the session (see ../home/shell.nix)
  #   ~/.config-ii/   illogical-impulse  (everything below)
  #
  # The split was built so this session could sit beside caelestia without
  # either touching the other's files. Caelestia has since been dropped and
  # this is the only session left, but the split is kept: it is what makes the
  # whole tree a store symlink with a small, listed set of mutable exceptions
  # (see mutablePaths), rather than home-manager and the dots fighting over
  # one ~/.config.
  #
  # That split is cheap because the shell half of these dots is already
  # XDG-aware — 33 sites across ii and end4-pC read
  # ${XDG_CONFIG_HOME:-$HOME/.config} rather than hardcoding. Everything else
  # that matters (fish, kitty, foot, fontconfig, kdeglobals, Kvantum, matugen,
  # fuzzel, wlogout, mpv, dconf) honours XDG_CONFIG_HOME on its own, so
  # nothing here has to be told twice where its config lives.
  #
  # What is NOT XDG-aware is the Hyprland Lua config and a dozen helper
  # scripts, which spell $HOME/.config literally. Those are rewritten in the
  # `dots` derivation below.
  cfgDirName = ".config-ii";
  cfgDir = "${config.home.homeDirectory}/${cfgDirName}";

  # Which quickshell config the session starts. Both are installed side by
  # side under .config-ii/quickshell/, so this is only the default: `qs -c ii`
  # and `qs -c end4-pC` switch at runtime, no rebuild, no logout.
  qsConfig = "end4-pC";

  # Reads one of ./files, filling in its @name@ placeholders from `vars`.
  # The files hold exactly the text the derivations write, so moving a
  # script out of a Nix string changes no store path.
  fill = file: vars:
    lib.replaceStrings
      (map (n: "@${n}@") (lib.attrNames vars))
      (map toString (lib.attrValues vars))
      (builtins.readFile file);

  args = { inherit config inputs pkgs lib qsConfig fill; };

  python = import ./python.nix args;
  inherit (python) venv;
  terminals = import ./terminals.nix args;
  microtex = import ./microtex.nix args;

  # ── quickshell itself: the `qs` binary both configs run under.
  #
  # This used to live in ../home/caelestia.nix, reached through
  # inputs.caelestia-shell.inputs.quickshell — session B was running session
  # A's quickshell the whole time, which is why dropping that session started
  # with moving this. ../flake.nix now takes the same rev as a direct input,
  # so the store path is byte-identical to what was running before the move.
  #
  # The two overrides are upstream quickshell's own optional backends, off for
  # the same reason caelestia turned them off: X11 and i3/sway support compile
  # in Xlib and a sway IPC client that a Wayland-only Hyprland session never
  # calls. Keeping them would only widen the closure.
  #
  # withModules adds QML modules to the wrapper's import path. Only
  # qtimageformats here — the m3shapes module that used to be in this list is
  # caelestia's bar-workspace shape library, and these dots do not import it:
  # modules/common/widgets/MaterialShape.qml reads its own
  # `shapes/material-shapes.js`, the rounded-polygon-qmljs submodule the build
  # already asserts is present.
  #
  # The other five QML modules these dots need are not here but in
  # ../modules/ii-session.nix, exported as NIXPKGS_QT6_QML_IMPORT_PATH — see
  # the comment there for why the session variable rather than a second
  # wrapper.
  quickshell =
    (inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
      withX11 = false;
      withI3 = false;
    }).withModules [ pkgs.qt6.qtimageformats ];

  # ── SUPER+SHIFT+B → pwvucontrol, as a show/hide toggle.
  #
  # Also inherited from ../home/caelestia.nix, where session B's keybind patch
  # already borrowed it (see the SUPER+SHIFT+B rewrite in `dots` below, which
  # is the only caller now).
  #
  # pwvucontrol is GTK4 without single-instance handling, so a plain
  # `exec_cmd pwvucontrol` bind stacks a fresh window on every press. This
  # does the three-state toggle instead: launch if absent, focus if open but
  # unfocused, close if it is the active window.
  #
  # The class is matched case-insensitively on the substring rather than
  # pinned to the literal `com.saivert.pwvucontrol` app-id, so the bind keeps
  # working if upstream renames it.
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

  # ── Gemini 3.6 Flash in the AI sidebar.
  #
  # Upstream's built-in Gemini entries stop at gemini-3-flash-preview. This one
  # goes first in the models object, so it is also modelList[0] — the fallback
  # when Persistent holds no model or one that no longer exists. Same key_id
  # as the other Gemini entries, so one key in the keyring serves all three.
  #
  # Patched into Ai.qml rather than added through config.json's ai.extraModels:
  # config.json is written by the shell at runtime and holds nothing this repo
  # seeds, the same reason the capture paths below are QML defaults.
  #
  # Checked against the API with a real key: models/gemini-3.6-flash exists
  # and answers streamGenerateContent, which is the endpoint GeminiApiStrategy
  # calls.
  #
  # ── DeepSeek V4 Flash through gonka24, second.
  #
  # An OpenAI-compatible endpoint, so upstream's OpenAiApiStrategy drives it
  # unchanged, with its key under key_id "gonka24". One thing it needs:
  # extraParams sends `tools: []`, i.e. no sidebar functions for this model.
  # OpenAiApiStrategy ignores tool_calls entirely, and this model reaches for
  # the tools readily — asked a plain question it streamed a run_shell_command
  # call, which the sidebar would have shown as an empty reply.
  # tool_choice "none" is no fix here: the model still generates the call and
  # the provider drops it, again an empty reply (3 of 3 runs). `tools: null` is
  # rejected ("Expected array"); `[]` answers normally. All tested against the
  # endpoint with a real key.
  geminiModel = "gemini-3.6-flash";
  gonkaModel = "deepseek-v4-flash-0731";
  aiModelEntries = pkgs.writeText "ii-ai-extra-models" ''
            "${geminiModel}": aiModelComponent.createObject(this, {
                "name": "Gemini 3.6 Flash",
                "icon": "google-gemini-symbolic",
                "description": Translation.tr("Online | Google's model\nFast, with thinking. Added by the NixOS config."),
                "homepage": "https://aistudio.google.com",
                "endpoint": "https://generativelanguage.googleapis.com/v1beta/models/${geminiModel}:streamGenerateContent",
                "model": "${geminiModel}",
                "requires_key": true,
                "key_id": "gemini",
                "key_get_link": "https://aistudio.google.com/app/apikey",
                "key_get_description": Translation.tr("**Pricing**: free. Data used for training.\n\n**Instructions**: Log into Google account, allow AI Studio to create Google Cloud project or whatever it asks, go back and click Get API key"),
                "api_format": "gemini",
            }),
            "deepseek-v4-flash": aiModelComponent.createObject(this, {
                "name": "DeepSeek V4 Flash (Gonka)",
                "icon": "deepseek-symbolic",
                "description": Translation.tr("Online | DeepSeek's model via gonka24\nOpenAI-compatible endpoint. Sidebar functions are off for this model. Added by the NixOS config."),
                "homepage": "https://gonka24.com",
                "endpoint": "https://api.gonka24.com/v1/chat/completions",
                "model": "${gonkaModel}",
                "requires_key": true,
                "key_id": "gonka24",
                "api_format": "openai",
                "extraParams": { "tools": [] },
            }),
  '';

  # ── Where captures go.
  #
  # Both on /mnt/shared rather than under $HOME so the files are reachable from
  # the other OS on this machine. The dots read these from config.json at
  # runtime (Config.options.screenSnip.savePath and .screenRecord.savePath), so
  # what is patched below is the QML default — Settings can still override it,
  # and once it does, config.json wins.
  screenshotDir = "/mnt/shared/Pictures/Screenshots";
  recordingDir = "/mnt/shared/Videos";

  # Print: save a file AND copy, the way caelestia's Print does. Upstream's
  # bind is `grim ... - | wl-copy`, clipboard only.
  #
  # A script rather than a longer string in keybinds.lua: the bind would
  # otherwise be shell inside a Lua string inside a sed replacement inside a
  # Nix string, and the quoting stops being reviewable. Absolute store paths so
  # it does not depend on what happens to be on PATH in the session.
  printScreenshot = pkgs.writeShellScript "ii-print-screenshot" ''
    export PATH=${lib.makeBinPath [ pkgs.grim pkgs.jq pkgs.wl-clipboard pkgs.libnotify pkgs.coreutils pkgs.hyprland ]}
    dir="${screenshotDir}"
    mkdir -p "$dir"
    f="$dir/screenshot-$(date '+%Y-%m-%d_%H.%M.%S').png"
    grim -o "$(hyprctl activeworkspace -j | jq -r '.monitor')" - | tee "$f" | wl-copy
    notify-send "Screenshot saved" "$f" -a Screenshot -i image-x-generic
  '';

  # ── SUPER+SHIFT+Q (hold): close every window, one at a time.
  #
  # Current workspace first, then 1, 2, 3, … and the special workspaces last,
  # switching to each so both the workspace slide and each window's popin-out
  # animation are visible. Releasing Q (with SUPER+SHIFT still down) or SUPER
  # stops it where it is; letting go of SHIFT alone does not.
  #
  # Press and release are two separate exec_cmds, so nothing orders them: on a
  # quick tap the release can land before this script has even started. The
  # keybind therefore hands both halves the same per-press token, and "stop"
  # just drops a file named after it — whichever side runs first, the start
  # side sees it. The 300ms grace before the first close is what makes a tap a
  # no-op rather than "closes one window".
  #
  # Each window gets the same polite close as SUPER+Q; one that is still there
  # 1.5s later (an unsaved-changes prompt, a hung app) is force-killed —
  # Hyprland's kill dispatcher first, then SIGKILL on its pid as a backstop.
  closeSequential = pkgs.writeShellScript "ii-close-sequential" ''
    export PATH=${lib.makeBinPath [ pkgs.hyprland pkgs.jq pkgs.libnotify pkgs.coreutils pkgs.findutils pkgs.util-linux ]}
    mode=$1 token=$2
    [ -n "$token" ] || exit 1
    dir="''${XDG_RUNTIME_DIR:-/tmp}/ii-close-sequential"
    mkdir -p "$dir"
    stopf="$dir/stop-$token"
    if [ "$mode" = stop ]; then touch "$stopf"; exit 0; fi

    find "$dir" -name 'stop-*' -mmin +1 -delete 2>/dev/null
    exec 9>"$dir/lock"
    flock -n 9 || exit 0

    stopped() { [ -e "$stopf" ]; }
    # Sleep $1 ms in 50ms slices; fails as soon as the keys are released.
    nap() {
      local n=$(( $1 / 50 ))
      while [ "$n" -gt 0 ]; do
        stopped && return 1
        sleep 0.05
        n=$(( n - 1 ))
      done
      ! stopped
    }
    alive() { hyprctl clients -j | jq -e --arg a "$1" 'any(.[]; .address == $a)' >/dev/null; }

    # Counted as "windows from the starting set that are gone", so a
    # force-kill that takes several windows of one process with it (every
    # VS Code window shares a pid) is counted right.
    before=$(hyprctl clients -j | jq -c '[.[].address]')
    finish() {
      rm -f "$stopf"
      n=$(hyprctl clients -j | jq --argjson s "$before" '$s - [.[].address] | length')
      [ "''${n:-0}" -gt 0 ] || exit 0
      if stopped; then body="Stopped on release"; else body="All workspaces done"; fi
      notify-send "Closed $n windows" "$body" -a Hyprland -i window-close
    }
    trap finish EXIT

    nap 300 || exit 0

    cur=$(hyprctl activeworkspace -j | jq '.id')
    mapfile -t order < <(hyprctl workspaces -j | jq -r --argjson cur "$cur" '
      [.[] | select(.windows > 0)] as $ws
      | ($ws | map(select(.id == $cur)))
        + ($ws | map(select(.id > 0 and .id != $cur)) | sort_by(.id))
        + ($ws | map(select(.id < 0)) | sort_by(.name))
      | .[] | "\(.id) \(.name)"')

    for entry in "''${order[@]}"; do
      id=''${entry%% *} name=''${entry#* }
      if [ "$id" -lt 0 ]; then
        # toggle_special hides it again if it is already open somewhere.
        hyprctl monitors -j | jq -e --arg n "$name" 'any(.[]; .specialWorkspace.name == $n)' >/dev/null ||
          hyprctl dispatch "hl.dsp.workspace.toggle_special(\"''${name#special:}\")" >/dev/null
        nap 400 || exit 0
      elif [ "$id" != "$(hyprctl activeworkspace -j | jq '.id')" ]; then
        hyprctl dispatch "hl.dsp.focus({ workspace = $id })" >/dev/null
        nap 400 || exit 0
      fi

      # Most recently focused first, i.e. the window actually on top. The
      # cap only guards against something that respawns its window forever.
      for _ in $(seq 1 64); do
        read -r addr pid < <(hyprctl clients -j | jq -r --argjson id "$id" '
          [.[] | select(.workspace.id == $id)] | sort_by(.focusHistoryID) | first
          | select(. != null) | "\(.address) \(.pid)"')
        [ -n "$addr" ] || break

        hyprctl dispatch "hl.dsp.window.close({ window = \"address:$addr\" })" >/dev/null
        for _ in $(seq 1 15); do
          alive "$addr" || break
          nap 100 || exit 0
        done
        if alive "$addr"; then
          hyprctl dispatch "hl.dsp.window.kill({ window = \"address:$addr\" })" >/dev/null
          nap 500 || exit 0
          if alive "$addr" && [ "''${pid:-0}" -gt 1 ]; then kill -9 "$pid" 2>/dev/null; fi
        fi
        addr=""
        nap 250 || exit 0
      done
    done
  '';

  # ── Restarting the shell.
  #
  # Upstream's bind is `killall ydotool qs quickshell; qs -c $qsConfig &`, and
  # on NixOS the kill half is a no-op: wrapQtAppsHook renames the process, so
  # /proc/<pid>/comm reads `.quickshell-wra` and killall — which matches on
  # comm — finds neither `qs` nor `quickshell`. The start half still runs, so
  # every press of CTRL+SUPER+R left the old instance alive and added another
  # one: two bars, then three. Upstream knows about this; it is an open TODO in
  # their own sdata/dist-nix/README.md ("should be .quickshell-wra and
  # .Hyprland-wrapp when installed via Nix").
  #
  # `qs kill` is quickshell's own subcommand and the right answer here. Unlike
  # the caelestia session — where `qs -c caelestia kill` could never work
  # because that shell runs from a store path — these configs really do live at
  # $XDG_CONFIG_HOME/quickshell/<name>, so -c resolves. pkill on the full
  # command line stays as a backstop for an instance that is too wedged to
  # answer its IPC socket.
  shellRestart = pkgs.writeShellScript "ii-shell-restart" ''
    export PATH=${lib.makeBinPath [ pkgs.procps pkgs.psmisc pkgs.coreutils ]}:$PATH
    cfg="''${qsConfig:-${qsConfig}}"
    killall ydotool 2>/dev/null || true

    # `qs kill` terminates ONE instance per call — it prints "Killed <id>" and
    # returns, leaving any others running. Looping matters because the whole
    # reason this script exists is that duplicates accumulate.
    for _ in 1 2 3 4 5; do
      pgrep -f 'bin/quickshell -c' >/dev/null 2>&1 || break
      qs -c "$cfg" kill >/dev/null 2>&1 || break
    done

    # Backstop for an instance too wedged to answer its IPC socket. The pattern
    # cannot match this script: its own cmdline is the store path below.
    pkill -f 'bin/quickshell -c' 2>/dev/null || true

    # Wait for them to actually exit. Starting the replacement while the old
    # one still holds its layer surfaces is how you get two bars for a moment,
    # and if the old one then fails to exit, permanently.
    for _ in $(seq 1 50); do
      pgrep -f 'bin/quickshell -c' >/dev/null 2>&1 || break
      sleep 0.1
    done

    exec qs -c "$cfg" -d
  '';

  # ── The two plasma-workspace tools the colour pipeline shells out to.
  #
  # kde-material-you-colors is the Qt half of that pipeline: matugen/templates/
  # kde/kde-material-you-colors-wrapper.sh runs it on every wallpaper change,
  # it writes .colors files into ~/.local/share/color-schemes, and then calls
  # `plasma-apply-colorscheme` to apply one and `plasma-changeicons` to set the
  # icon theme (plasma_utils.py:89-96). Both live only in
  # kdePackages.plasma-workspace, and a missing one is exit 127 with the
  # generation half still succeeding — which reads on screen as "the Qt apps
  # ignored the wallpaper".
  #
  # This used to be a Python stand-in (./ii-plasma-apply-colorscheme.py, now
  # deleted) written to avoid plasma-workspace's 4307 MB closure. That premise
  # was wrong: `nix why-depends /run/current-system <plasma-workspace>` walks
  # system-path -> xdg-desktop-portal-kde -> plasma-workspace, so it is already
  # in the system closure and adding it costs zero new store paths. Measured,
  # not assumed: 0 of its 607 closure paths are absent from the running system.
  #
  # Symlinks rather than home.packages = [ plasma-workspace ], because what is
  # NOT wanted is the rest of it — 25 binaries including plasmashell and
  # startplasma-wayland on PATH, its .desktop entries in the launcher, and its
  # 8 D-Bus activation services becoming reachable through the profile's
  # share/dbus-1 (the profile IS in XDG_DATA_DIRS). The systemd units and the
  # four XDG autostart entries are inert either way — the units are WantedBy
  # plasma targets a Hyprland session never reaches, and the autostart files
  # are all OnlyShowIn=KDE.
  #
  # A symlink is enough for both: Qt resolves applicationDirPath through
  # /proc/self/exe, which follows it back to the real store path, so neither
  # binary loses track of its own resources. Verified by running both through
  # one.
  #
  # plasma-changeicons comes out of libexec/, not bin/ — it is a helper
  # upstream never meant to be called by hand, and kde-material-you-colors
  # calls it by bare name off PATH anyway.
  plasmaTools = pkgs.runCommand "ii-plasma-tools" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.kdePackages.plasma-workspace}/bin/plasma-apply-colorscheme $out/bin/
    ln -s ${pkgs.kdePackages.plasma-workspace}/libexec/plasma-changeicons $out/bin/
  '';

  # ── kcmshell6 and systemsettings, able to load the Bluetooth and Network KCMs.
  #
  # Both KCMs installed fine and still failed at load, each for a reason the
  # nixpkgs Plasma module would have hidden and this session does not:
  #
  #   kcm_bluetooth          main.qml:22 imports org.kde.bluezqt, which lives
  #                          in bluez-qt. bluedevil links the C++ library but
  #                          propagates nothing, so no QML path held it —
  #                          "module org.kde.bluezqt is not installed".
  #   kcm_networkmanagement  a QWidgets KCM that finds its main.qml through
  #                          XDG_DATA_DIRS (share/kcm_networkmanagement/qml).
  #                          The per-user profile only links the share/ subdirs
  #                          listed in environment.pathsToLink, and Plasma's
  #                          module is what normally widens that to all of
  #                          /share. Not found means an empty QQuickWidget: a
  #                          fully transparent window and no error at all.
  #                          Once found, its ConnectionItem.qml needs
  #                          org.kde.plasma.components (libplasma), which in
  #                          turn needs org.kde.ksvg.
  #
  # Wrapped here rather than put on the session's QML path in
  # ../modules/ii-session.nix, so libplasma never lands on quickshell's import
  # path. Verified by running both KCMs with exactly these additions: no QML
  # errors, and both render.
  kcmHosts = pkgs.symlinkJoin {
    name = "ii-kcm-hosts";
    paths = [ pkgs.kdePackages.kcmutils pkgs.kdePackages.systemsettings ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      for b in kcmshell6 systemsettings; do
        wrapProgram $out/bin/$b \
          --prefix NIXPKGS_QT6_QML_IMPORT_PATH : ${lib.concatMapStringsSep ":" (p: "${p}/lib/qt-6/qml") [
            pkgs.kdePackages.bluez-qt
            pkgs.kdePackages.libplasma
            pkgs.kdePackages.ksvg
          ]} \
          --prefix XDG_DATA_DIRS : ${pkgs.kdePackages.plasma-nm}/share
      done
    '';
  };

  # ── Automatic light/dark from the wallpaper.
  #
  # These dots never look at the wallpaper to decide light or dark. The mode
  # comes from gsettings and nothing else (switchwall.sh, the
  # `if [[ -z "$mode_flag" ]]` branch), which is why a white wallpaper still
  # renders a dark palette — matugen is handed --mode dark and derives a dark
  # scheme from that image's hues. Picking an accent colour does not change it
  # either; --color only passes the colour through to matugen.
  #
  # This replaces that branch. The decision still lands in the same variable,
  # so it flows on into `pre_process "$mode_flag"` further down, which is what
  # writes org.gnome.desktop.interface color-scheme and gtk-theme — so the
  # portal, GTK, Qt and session A all follow without any extra plumbing.
  #
  # On by default, off by one command, because a luminance threshold is always
  # wrong for some images and you will want to override it. An explicit
  # --mode still wins: the Settings light/dark buttons keep working as a
  # one-off, and the next wallpaper change re-derives.
  # Calibrated against the torii pair, which is the reference: "torii dark"
  # measures 0.541 and "torii white" 0.907, so anything in (0.541, 0.907] sorts
  # them correctly. 0.6 is the low end of that window on purpose — it is the
  # smallest move from a neutral 0.5 that satisfies the constraint, so it
  # reclassifies torii dark and nothing else in the current set:
  #
  #   wallhaven-vg8y8m  0.051  dark
  #   Cyrene            0.158  dark
  #   torii dark        0.541  dark   <- the one this threshold exists for
  #   Kokomi            0.692  light
  #   wallhaven-exmppk  0.772  light
  #   Escoffier         0.792  light
  #   torii white       0.907  light
  #
  # Raising it further (0.72 would also make Kokomi dark) is a taste call, not
  # a correctness one — this single value is the only thing to edit.
  autoLightDarkThreshold = "0.6";

  autoLightDark = pkgs.writeShellScript "ii-auto-lightdark" ''
    export PATH=${lib.makeBinPath [ pkgs.imagemagick pkgs.gawk pkgs.coreutils ]}
    flag="''${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse/auto-lightdark"

    # Upstream's rule as the fallback, but read through dconf rather than
    # gsettings. ../home/qt.nix documents why: glib.bin's gsettings only
    # reaches the real database when GIO_EXTRA_MODULES points at dconf's GIO
    # module, and without it every read silently returns the SCHEMA DEFAULT —
    # 'default' for color-scheme, which this function would then report as
    # light. A wrong answer that looks like a working read is the worst kind
    # for something that runs unattended on every wallpaper change.
    from_dconf() {
      case "$(${pkgs.dconf}/bin/dconf read /org/gnome/desktop/interface/color-scheme 2>/dev/null | tr -d "'")" in
        prefer-dark) echo dark ;;
        *)           echo light ;;
      esac
    }

    # Missing flag file means on.
    # $2 is whatever --mode the caller asked for, empty if none. With auto off
    # it passes straight through, so upstream's own precedence is untouched:
    # an explicit mode wins, and with neither it falls back to dconf below.
    explicit="''${2:-}"
    passthrough() { [ -n "$explicit" ] && echo "$explicit" || from_dconf; }

    [ "$(cat "$flag" 2>/dev/null)" = "0" ] && { passthrough; exit 0; }

    # Auto on outranks the explicit mode — the Settings light/dark buttons
    # stop having an effect until `ii-lightdark-auto off`. That is the asked-for
    # behaviour: one switch decides, rather than two that quietly fight.
    img="$1"

    # Not every caller passes an image. switchwall.sh regenerates colours from
    # several paths — a bare run, --noswitch, the shell re-applying after a
    # restart — and with no image to measure this used to fall through to
    # dconf, which re-applied whatever mode was already set. The effect was a
    # mode that latched: change the wallpaper to a dark one, have anything
    # regenerate colours without naming it, and the old light mode came back
    # and stayed. So fall back to the wallpaper the shell actually has
    # configured before falling back to the previous mode.
    if [ -z "$img" ] || [ ! -f "$img" ]; then
      cfg="''${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse/config.json"
      img="$(${pkgs.jq}/bin/jq -r '.background.wallpaperPath // empty' "$cfg" 2>/dev/null)"
    fi
    [ -n "$img" ] && [ -f "$img" ] || { passthrough; exit 0; }
    # A video is measured by its still frame, the same one its palette comes
    # from (see videoFrame).
    case "''${img,,}" in
      *.mp4|*.webm|*.mkv|*.avi|*.mov)
        img="$(${videoFrame} "$img")" || { passthrough; exit 0; } ;;
    esac

    # Mean of the image collapsed to one grey pixel: 0 is black, 1 is white.
    mean="$(magick "$img" -colorspace Gray -resize 1x1! -format '%[fx:mean]' info: 2>/dev/null)"
    [ -n "$mean" ] || { passthrough; exit 0; }
    # Below the threshold is dark, at or above it is light.
    awk -v m="$mean" -v t="${autoLightDarkThreshold}" 'BEGIN { print (m >= t) ? "light" : "dark" }'
  '';

  autoLightDarkCtl = pkgs.writeShellScriptBin "ii-lightdark-auto" ''
    export PATH=${lib.makeBinPath [ pkgs.jq pkgs.coreutils ]}
    cfgdir="''${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse"
    flag="$cfgdir/auto-lightdark"
    state() { [ "$(cat "$flag" 2>/dev/null)" = "0" ] && echo off || echo on; }

    case "''${1:-status}" in
      status) echo "auto light/dark: $(state)" ;;
      on|off)
        mkdir -p "$cfgdir"
        [ "$1" = "on" ] && echo 1 > "$flag" || echo 0 > "$flag"
        echo "auto light/dark: $(state)"
        # Re-derive straight away for the wallpaper that is already set.
        if [ "$1" = "on" ]; then
          wp="$(jq -r '.background.wallpaperPath // empty' "$cfgdir/config.json" 2>/dev/null)"
          [ -n "$wp" ] && exec "''${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/${qsConfig}/scripts/colors/switchwall.sh" --noswitch --image "$wp"
        fi
        ;;
      toggle) [ "$(state)" = "on" ] && exec "$0" off || exec "$0" on ;;
      *) echo "usage: ii-lightdark-auto [status|on|off|toggle]" >&2; exit 2 ;;
    esac
  '';

  # ── Zen's accent, from this session's palette.
  #
  # ../home/zen-wallpaper-accent.nix carries the whole explanation of why Zen
  # needs a CSS file pushed into its profile rather than a pref, and
  # ../home/zen.nix owns the userChrome.css that consumes it. Only two things
  # are session B's business: which colours.json is the source, and what runs
  # the script — both below.
  #
  # Session B only, which falls out of the source path on its own: this is
  # matugen's m3colors output as ~/.config-ii/matugen/config.toml routes it,
  # nothing else writes it. It was chosen when caelestia still existed and
  # wrote its own palette to ~/.local/state/caelestia/scheme.json; that file
  # is now stale and read by nobody.
  zenAccent = import ../zen-wallpaper-accent.nix { inherit pkgs; };
  zenAccentColors = "${config.home.homeDirectory}/.local/state/quickshell/user/generated/colors.json";

  # ── Idle and lid: the display is the only thing that ever turns off.
  #
  # The machine never sleeps on its own any more — logind ignores the lid and
  # both power keys (../modules/power.nix), and the one thing left that could
  # still end a session unattended is UPower's poweroff at 12%, same file.
  # What remains here is purely about the screen:
  #
  #   on AC       nothing, ever: no screen-off, no lock
  #   on battery  screen off after 5 min idle, lock at 15 min
  #   lid closed  the internal panel goes dark, nothing else changes
  #
  # hypridle has no notion of power source, so every listener goes through
  # this script and the AC check happens at the moment the timeout fires.
  # Called by name from hypridle.conf rather than by store path: that file is
  # seed-once (see mutablePaths) and outlives any store path baked into it.
  #
  # Two Hyprland behaviours, both verified on this machine, shape the lid half:
  #
  # A dpms dispatch naming an output that is not active does not fail — it
  # falls through to EVERY monitor. With eDP-1 switched off in nwg-displays,
  # a lid close would have blacked out the HDMI screen. So the panel is only
  # ever named after `hyprctl monitors` (which lists active outputs only) has
  # confirmed it is there.
  #
  # And key_press/mouse_move_enables_dpms wake a per-monitor dpms-off just as
  # they wake a global one: with the lid shut, the first touch of an external
  # mouse lit the closed panel again. Those two are turned off for as long as
  # the lid is closed, and `wake` (hypridle's on-resume) takes over waking the
  # other screens without touching the panel.
  displayPower = pkgs.writeShellScriptBin "ii-display-power" ''
    export PATH=${lib.makeBinPath [ pkgs.hyprland pkgs.jq pkgs.coreutils pkgs.gnugrep pkgs.systemd ]}

    on_battery() { [ "$(cat /sys/class/power_supply/AC/online 2>/dev/null)" = 0 ]; }
    lid_closed() { grep -qs closed /proc/acpi/button/lid/*/state; }
    panel() { hyprctl monitors -j | jq -r 'first(.[] | select(.name | startswith("eDP")) | .name) // empty'; }
    dpms() { hyprctl dispatch "hl.dsp.dpms({ action = \"$1\"''${2:+, monitor = \"$2\"} })" >/dev/null; }
    wake_on_input() {
      hyprctl dispatch "function() hl.config({ misc = { mouse_move_enables_dpms = $1, key_press_enables_dpms = $1 } }) end" >/dev/null
    }

    case "''${1:-}" in
      lid-close)
        wake_on_input false
        p=$(panel)
        if [ -n "$p" ]; then dpms disable "$p"; fi
        ;;
      lid-open)
        wake_on_input true
        p=$(panel)
        if [ -n "$p" ]; then dpms enable "$p"; fi
        ;;
      idle-off)
        if on_battery; then dpms disable; fi
        ;;
      idle-lock)
        if on_battery; then loginctl lock-session; fi
        ;;
      wake)
        # Per monitor, and only the ones that are actually off, so a resume
        # on AC (where idle-off did nothing) touches no screen at all.
        skip=
        if lid_closed; then skip=$(panel); fi
        hyprctl monitors -j | jq -r '.[] | select(.dpmsStatus | not) | .name' |
        while read -r m; do
          if [ "$m" != "$skip" ]; then dpms enable "$m"; fi
        done
        ;;
      *)
        echo "usage: ii-display-power lid-close|lid-open|idle-off|idle-lock|wake" >&2
        exit 2
        ;;
    esac
    exit 0
  '';

  # Replaces upstream's hypridle.conf outright: its three listeners (lock 5m,
  # screen off 10m, suspend 15m) all fire regardless of power source, and the
  # suspend one is exactly what this setup is removing. general {} is
  # upstream's, verbatim — manual suspend (SUPER+SHIFT+L) still locks first.
  #
  # Seed-once like the rest of mutablePaths: an existing
  # ~/.config-ii/hypr/hypridle.conf is not replaced. Delete it to pick this up.
  hypridleConf = pkgs.writeText "hypridle.conf" ''
    $lock_cmd = hyprctl dispatch 'hl.dsp.global("quickshell:lock")' & pidof qs quickshell hyprlock || hyprlock
    $suspend_cmd = systemctl suspend || loginctl suspend

    general {
        lock_cmd = $lock_cmd
        before_sleep_cmd = loginctl lock-session
        after_sleep_cmd = hyprctl dispatch 'hl.dsp.global("quickshell:lockFocus")'
        inhibit_sleep = 3
    }

    # Battery only; both are no-ops on AC (see ii-display-power).
    listener {
        timeout = 300 # 5mins
        on-timeout = ii-display-power idle-off
        on-resume = ii-display-power wake
    }

    listener {
        timeout = 900 # 15mins
        on-timeout = ii-display-power idle-lock
    }
  '';

  # ── Video wallpapers.
  #
  # switchwall.sh plays a video wallpaper with mpvpaper on Hyprland's
  # background layer, and the shell's own wallpaper window — the bottom layer,
  # just above it — goes transparent to let it through. Everything that needs
  # a *picture* of the video (the palette, the light/dark measure, the tile in
  # the selector, the preview while arrowing through it) uses one still frame
  # instead. Upstream extracted that frame in one place, switchwall.sh, and
  # only once the video was already being applied, so everything that runs
  # before that point had nothing to look at: scheme detection fed the .mp4
  # itself to a Python image loader, the selector never listed videos at all
  # (Wallpapers.qml's extension list still says "TODO: add videos"), and the
  # preview showed the thumbnail of whatever wallpaper was already set.
  #
  # One helper, so the frame has one name and one recipe wherever it is asked
  # for. The name is upstream's — <basename>.jpg under hypr/custom/scripts/
  # mpvpaper_thumbnails, writable because hypr/custom is in mutablePaths —
  # which keeps background.thumbnailPath meaning what the rest of the shell
  # already reads it as. First frame, as upstream; redone when the video is
  # newer than it. Written under a temp name and moved into place, because the
  # thumbnail pass and switchwall.sh can ask for the same frame at once and the
  # shell may be reading it. -q:v 2 because this frame is shown full screen,
  # during the preview and the transition into the video, and ffmpeg's default
  # JPEG quality is visibly blocky at 1080p.
  videoFrame = pkgs.writeShellScript "ii-video-frame" ''
    export PATH=${lib.makeBinPath [ pkgs.ffmpeg pkgs.coreutils ]}
    src="$1"
    dir="''${XDG_CONFIG_HOME:-$HOME/.config}/hypr/custom/scripts/mpvpaper_thumbnails"
    frame="$dir/$(basename "$src").jpg"
    if [ ! -s "$frame" ] || [ "$src" -nt "$frame" ]; then
      mkdir -p "$dir"
      tmp="$frame.$$.jpg"
      if ! ffmpeg -nostdin -v error -y -i "$src" -frames:v 1 -q:v 2 "$tmp"; then
        rm -f "$tmp"
        exit 1
      fi
      mv -f "$tmp" "$frame"
    fi
    echo "$frame"
  '';

  # What mpvpaper actually plays: the video itself, or a 1080p30 copy of it.
  #
  # Measured on this machine with a 4K60 H.264 wallpaper (40 Mbit/s), one
  # monitor: the iGPU's video-decode engine 79% busy, and 211 of ~300 frames
  # dropped in 5s — every monitor runs its own mpvpaper, so two of those are
  # past what the engine can do. Capping at playback does not help: mpv's
  # fps filter still has to decode every frame, since each is coded against
  # the others (79% again, 86 of 150 dropped). A 1080p30 copy decodes at 13%
  # with nothing dropped, so the copy is made once and played from then on.
  #
  # Only ever smaller: scaled down until it just covers a 1920x1080 screen
  # (mpvpaper crops to fill, so a wider video keeps its full height), and
  # dropped to 30fps only if it is faster. Anything already within both is
  # played as it is. Made on the iGPU (35s for a 21s 4K60 clip — the 4K
  # decode is the slow half, the low-power encoder was no faster) and
  # indistinguishable from a proper downscale at 1080p; libx264 is the
  # fallback for anything VA-API will not decode. The copy lives in the cache,
  # keyed on the source's path, size and mtime, so replacing a video makes a
  # new one and clearing the cache only costs one more conversion.
  #
  # A bin, not a store path, because the restore script switchwall.sh writes
  # into hypr/custom calls it at every login and outlives any store path.
  #
  # --cached never converts: it prints what to play only if that needs no
  # conversion or the copy is already made, and fails otherwise. The lock
  # screen asks that way (see mpvpaperCtl), so locking never waits on a
  # conversion. The lock video's copy is started as soon as it is picked
  # (see the switchwall.sh patch), which is the second way two conversions of
  # one video can overlap — the flock makes the later one wait for the first
  # and then use its copy.
  videoProxy = pkgs.writeShellScriptBin "ii-video-proxy" ''
    export PATH=${lib.makeBinPath [ pkgs.ffmpeg pkgs.coreutils pkgs.gawk pkgs.libnotify pkgs.util-linux ]}
    cached=
    if [ "''${1:-}" = --cached ]; then cached=1; shift; fi
    src="''${1:-}"
    [ -f "$src" ] || { echo "usage: ii-video-proxy [--cached] <video>  (prints the file to play)" >&2; exit 2; }
    real="$(realpath "$src")"

    IFS=, read -r w h rate < <(ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height,avg_frame_rate -of csv=p=0 "$real")
    if [ -z "$w" ] || [ -z "$h" ]; then echo "$src"; exit 0; fi

    read -r tw th shrink slow < <(awk -v w="$w" -v h="$h" -v r="$rate" 'BEGIN {
      s = 1920 / w; if (1080 / h > s) s = 1080 / h; if (s > 1) s = 1
      n = split(r, f, "/"); fps = (n == 2 && f[2] > 0) ? f[1] / f[2] : f[1] + 0
      printf "%d %d %d %d\n", int(w * s / 2 + 0.5) * 2, int(h * s / 2 + 0.5) * 2, (s < 0.99), (fps > 30.5)
    }')
    if [ "$shrink" = 0 ] && [ "$slow" = 0 ]; then echo "$src"; exit 0; fi

    dir="''${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/wallpaper-proxies"
    key="$(printf '%s %s' "$real" "$(stat -c '%s %Y' "$real")" | sha1sum | cut -c1-12)"
    base="$(basename "$real")"
    out="$dir/''${base%.*}.$key.mp4"
    if [ -s "$out" ]; then echo "$out"; exit 0; fi
    [ -z "$cached" ] || exit 1

    mkdir -p "$dir"
    exec 9>"$out.lock"
    flock 9
    if [ -s "$out" ]; then echo "$out"; exit 0; fi
    notify-send -a "Wallpaper switcher" "Optimizing video wallpaper" \
      "$base: ''${w}x''${h} to ''${tw}x''${th}, at most 30fps. This happens once; it starts playing when done." || true
    tmp="$out.$$.mp4"
    hwvf="scale_vaapi=w=$tw:h=$th:format=nv12"
    swvf="scale=$tw:$th:flags=lanczos"
    if [ "$slow" = 1 ]; then hwvf="fps=30,$hwvf"; swvf="fps=30,$swvf"; fi
    if ffmpeg -nostdin -v error -y -hwaccel vaapi -hwaccel_output_format vaapi -i "$real" \
         -an -vf "$hwvf" -c:v h264_vaapi -qp 20 "$tmp" \
      || ffmpeg -nostdin -v error -y -i "$real" \
         -an -vf "$swvf" -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p "$tmp"; then
      mv -f "$tmp" "$out"
      echo "$out"
    else
      rm -f "$tmp"
      notify-send -a "Wallpaper switcher" -u critical "Could not optimize video wallpaper" \
        "$base plays as it is." || true
      echo "$src"
    fi
  '';

  # Pause or resume one monitor's video, over the mpv IPC socket switchwall.sh
  # now opens per output (see the dots patch). The asked-for behaviour is that
  # the video stops only while something covers it: a fullscreen window, or
  # the overview (see videoQml.background for why that one matters). mpvpaper's own
  # --auto-pause cannot do that here: it pauses when the compositor stops
  # sending frame callbacks, and Hyprland does not stop — tested on this
  # machine, an mpvpaper covered edge to edge by the shell's opaque wallpaper
  # kept decoding for as long as it ran. The shell already tracks fullscreen
  # per monitor (for hideWhenFullscreen), so it sends the pause itself. Paused,
  # the same test used 1 tick of CPU per 2s against 25 playing.
  #
  # Waits for the socket, because the shell can ask the moment a wallpaper
  # goes live, and that is also the moment mpvpaper was spawned; the socket
  # took ~300ms to appear in testing. A stale one (mpvpaper is killed with -9,
  # which leaves the file behind) just refuses the connection.
  #
  # Given a video as well, it also makes that the one playing, which is how
  # the lock screen plays its own wallpaper live (see videoQml.background):
  # the same mpvpaper loads the lock video on lock and the desktop's again on
  # unlock, so there is never a second decoder, and the hidden desktop video
  # is not decoding meanwhile. loadfile starts the desktop video from the
  # beginning, as asked. With `lock`, a desktop that has no mpvpaper (a still
  # wallpaper) gets one started for the lock video, which `stop` kills on
  # unlock; and a lock video whose 1080p30 copy is not made yet is not played
  # at all (exit 3, so the lock screen keeps its frame) — the copy is started
  # instead, for the next lock. The desktop's own video is never held back
  # that way: it plays the original if it has to, as switchwall.sh does.
  #
  # Exits once mpv reports the file loaded, so the shell's reveal starts from
  # a video that is actually there. The shell serialises its calls per
  # monitor, so two never race on one mpvpaper.
  mpvpaperCtl = pkgs.writeShellScript "ii-mpvpaper-ctl" ''
    export PATH=${lib.makeBinPath [ pkgs.socat pkgs.coreutils pkgs.jq pkgs.procps pkgs.util-linux pkgs.mpvpaper videoProxy ]}
    usage() { echo "usage: ii-mpvpaper-ctl <monitor> pause|play [<video> [lock]] | stop" >&2; exit 2; }
    mon="''${1:-}"
    [ -n "$mon" ] || usage
    sock="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mpvpaper-$mon.sock"

    ipc() { socat -t 1 - "UNIX-CONNECT:$sock" 2>/dev/null <<< "$1" | jq -c 'select(has("error"))' 2>/dev/null | head -n 1; }
    get() { ipc "$(jq -nc --arg p "$1" '{command: ["get_property", $p]}')" | jq -r 'select(.error == "success" and .data != null) | .data | tostring'; }
    alive() { [ -n "$(get pid)" ]; }
    wait_alive() {
      for _ in $(seq 30); do
        alive && return 0
        sleep 0.1
      done
      return 1
    }

    stop() {
      pkill -9 -f "^[^ ]*mpvpaper .*/mpvpaper-$mon\.sock" || true
      rm -f "$sock"
    }

    case "''${2:-}" in
      stop) stop; exit 0 ;;
      pause) value=true ;;
      play)  value=false ;;
      *) usage ;;
    esac
    video="''${3:-}"
    lock="''${4:-}"

    if [ -z "$video" ]; then
      wait_alive || exit 1
      ipc "{\"command\":[\"set_property\",\"pause\",$value]}" >/dev/null
      exit 0
    fi

    if ! target="$(ii-video-proxy --cached "$video")"; then
      if [ -n "$lock" ]; then
        setsid -f ii-video-proxy "$video" >/dev/null 2>&1 < /dev/null
        exit 3
      fi
      target="$video"
    fi

    if ! alive; then
      if [ -n "$lock" ]; then
        rm -f "$sock"
        setsid -f mpvpaper -o "${videoOpts} input-ipc-server=$sock" "$mon" "$target" >/dev/null 2>&1 < /dev/null
        wait_alive || { stop; exit 1; }
      fi
      wait_alive || exit 1
    fi
    if [ "$(get path)" != "$target" ]; then
      ipc "$(jq -nc --arg p "$target" '{command: ["loadfile", $p, "replace"]}')" >/dev/null
    fi
    ipc "{\"command\":[\"set_property\",\"pause\",$value]}" >/dev/null

    for _ in $(seq 30); do
      if [ "$(get path)" = "$target" ] && [ -n "$(get playback-time)" ]; then exit 0; fi
      sleep 0.1
    done
    exit 1
  '';

  # mpvpaper's options, exactly as switchwall.sh sets them once the dots patch
  # has added profile=fast (checked there), for the mpvpaper the lock screen
  # starts itself.
  videoOpts = "no-audio loop hwdec=auto scale=bilinear interpolation=no video-sync=display-resample panscan=1.0 video-scale-x=1.0 video-scale-y=1.0 video-align-x=0.5 video-align-y=0.5 load-scripts=no profile=fast";

  # The QML the dots patch inserts for video wallpapers. Nix strips the common
  # indentation, so each is re-indented to its insertion point at build time,
  # the same way aiModelEntries is.
  videoQml = {
    # Images.qml, next to its image list.
    images = pkgs.writeText "ii-video-images.qml" ''
      readonly property list<string> validVideoExtensions: ["mp4", "webm", "mkv", "avi", "mov"]

      function isVideoByName(name: string): bool {
          const lower = (name || "").toLowerCase();
          return validVideoExtensions.some(t => lower.endsWith("." + t));
      }

      // Where ii-video-frame (NixOS config) puts a video's still frame.
      function videoFramePath(path: string): string {
          const name = (path || "").split("/").pop();
          return Directories.config.replace(/^file:\/\//, "") + "/hypr/custom/scripts/mpvpaper_thumbnails/" + name + ".jpg";
      }
    '';

    # Wallpapers.qml. confirmedPath is set by apply() and never cleared, so
    # after one pick from the selector the background ignored every later
    # change that did not come through apply() — a wallpaper chosen in the
    # file dialog, or set by switchwall.sh directly, never appeared. It only
    # has to bridge the moment before switchwall.sh writes the config; once
    # the config moves, the config is the truth again.
    #
    # requestThumbnails is for the video tiles below: thumbnails are only ever
    # generated from the selector's "Update thumbnails" button, and nothing
    # else makes one for a video. One pass covers the whole folder, and the
    # tiles already reload on thumbnailGenerated, so the first tile to ask is
    # enough and the rest are dropped while it runs.
    wallpapers = pkgs.writeText "ii-video-wallpapers.qml" ''
      property string configuredWallpaperPath: Config.options.background.wallpaperPath
      onConfiguredWallpaperPathChanged: root.confirmedPath = ""

      function requestThumbnails(size: string) {
          if (thumbgenProc.running)
              return;
          root.generateThumbnail(size);
      }
    '';

    # Inside the selector tile's ThumbnailImage: ask for a thumbnail once if a
    # video has none, and mark video tiles with a play badge. The badge is a
    # child of the image, so it fades in with it and sits inside its rounded
    # mask.
    tile = pkgs.writeText "ii-video-tile.qml" ''
      readonly property bool isVideo: Images.isVideoByName(sourcePath)
      property bool videoThumbnailRequested: false
      onStatusChanged: {
          if (status !== Image.Error || !isVideo || videoThumbnailRequested)
              return;
          videoThumbnailRequested = true;
          Wallpapers.requestThumbnails(thumbnailSizeName);
      }

      Rectangle {
          visible: thumbnailImage.isVideo
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: 6
          width: videoBadgeIcon.implicitWidth + 8
          height: width
          radius: width / 2
          color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.3)

          MaterialSymbol {
              id: videoBadgeIcon
              anchors.centerIn: parent
              text: "play_arrow"
              iconSize: Appearance.font.pixelSize.normal
              fill: 1
              color: Appearance.colors.colOnLayer0
          }
      }
    '';

    # Background.qml, per monitor. Only the applied wallpaper is ever playing
    # — mpvpaper is started by switchwall.sh, never by a preview — so only
    # then is there anything behind this window worth revealing. Upstream
    # revealed for any video path, which during a preview meant going
    # transparent over a video that was not running. A previewed video, or one
    # picked but not yet written to the config, now shows its frame like an
    # image.
    #
    # The reveal waits 500ms after the video goes live: switchwall.sh starts
    # mpvpaper just before it writes the config, and mpvpaper needs a moment
    # to put up its first frame; revealing at once shows the empty layer
    # beneath for that moment.
    #
    # A video that has never been through the thumbnail pass has no frame
    # until switchwall.sh extracts it, and it writes thumbnailPath straight
    # after, so a failed load is retried then.
    #
    # "Live" means the path ii-mpvpaper-ctl reports playing (playingPath), not
    # just the applied wallpaper, because the lock screen switches mpvpaper to
    # its own video (see mpvpaperCtl): locked, the lock video is revealed once
    # it has loaded, through the same 500ms delay; unlocked, the desktop's
    # again once it has loaded back. Until then — or for good, if the lock
    # video's 1080p30 copy is not made yet — the frame is shown, as for a
    # preview. With the lock blur on, the lock screen shows the blurred frame
    # as before and nothing is switched.
    #
    # Unlocked, the video pauses while a fullscreen window covers it. Locked,
    # it plays only if it is what the lock screen shows (so a still lock
    # wallpaper, or the blur, pauses the desktop video behind it), and pauses
    # while its screen is off.
    #
    # The pause also covers the niri-style overview, whose own blur (overviewBlurActive,
    # upstream's condition, reused as is) paints this window full screen with
    # a blurred copy of the still frame — the video is already hidden then.
    # Pausing it is what keeps the overview smooth: rules.lua blurs every
    # quickshell:* layer, and Hyprland caches the blur of what lies beneath
    # only until that changes. A video beneath changes it every frame, so the
    # full-screen blur was being redone at the video's frame rate while the
    # overview scrolled at the monitor's.
    background = pkgs.writeText "ii-video-background.qml" ''
      readonly property bool videoIsLive: bgRoot.wallpaperIsVideo
          && bgRoot.effectiveWallpaperPath === bgRoot.playingPath
      onVideoIsLiveChanged: {
          if (!bgRoot.videoIsLive) {
              videoRevealDelay.stop()
              bgRoot.videoRevealed = false
          } else if (!transitionAnim.running && !bgRoot.transitionPending) {
              videoRevealDelay.restart()
          }
      }
      Timer {
          id: videoRevealDelay
          interval: 500
          onTriggered: bgRoot.videoRevealed = bgRoot.videoIsLive
      }

      property string configuredThumbnailPath: Config.options.background.thumbnailPath
      onConfiguredThumbnailPathChanged: {
          if (!bgRoot.wallpaperIsVideo || wallpaper.status !== Image.Error) return
          wallpaper.source = ""
          wallpaper.source = bgRoot.wallpaperPath
      }

      // What this monitor's mpvpaper plays and whether it is paused, kept in
      // step by ii-mpvpaper-ctl one call at a time.
      readonly property string desktopVideo: Images.isVideoByName(Config.options.background.wallpaperPath)
          ? Config.options.background.wallpaperPath : ""
      property bool lockVideoFailed: false
      readonly property string lockVideo: {
          const lockWall = Config.options.background.lockWall
          if (!GlobalStates.screenLocked || bgRoot.lockVideoFailed || Config.options.lock.blur.enable) return ""
          if (lockWall === "" || lockWall === Config.options.background.wallpaperPath || !Images.isVideoByName(lockWall)) return ""
          return lockWall
      }
      readonly property string mpvVideo: bgRoot.lockVideo || bgRoot.desktopVideo
      readonly property bool monitorDpmsOff: GlobalStates.screenLocked
          && HyprlandData.monitors.find(m => m.name === bgRoot.modelData.name)?.dpmsStatus === false
      readonly property bool videoPaused: GlobalStates.screenLocked
          ? (bgRoot.monitorDpmsOff || Config.options.lock.blur.enable || bgRoot.effectiveWallpaperPath !== bgRoot.mpvVideo)
          : (bgRoot.activeWorkspaceWithFullscreen != undefined || bgRoot.overviewBlurActive)
      readonly property string mpvState: bgRoot.mpvVideo === "" ? "" : bgRoot.mpvVideo + (bgRoot.videoPaused ? "|pause" : "|play")
      onMpvStateChanged: Qt.callLater(bgRoot.syncMpv)

      // "none": the applied wallpaper, as switchwall.sh left it. Otherwise
      // what ii-mpvpaper-ctl last confirmed, "" while it is switching.
      property string mpvOverride: "none"
      readonly property string playingPath: bgRoot.mpvOverride === "none" ? bgRoot.desktopVideo : bgRoot.mpvOverride

      function syncMpv() {
          if (mpvProc.running) {
              mpvProc.again = true
              return
          }
          const video = bgRoot.mpvVideo
          mpvProc.video = video
          mpvProc.forLock = video !== "" && video === bgRoot.lockVideo
          if (video !== bgRoot.playingPath) bgRoot.mpvOverride = ""
          mpvProc.command = video === ""
              ? ["${mpvpaperCtl}", bgRoot.modelData.name, "stop"]
              : ["${mpvpaperCtl}", bgRoot.modelData.name, bgRoot.videoPaused ? "pause" : "play", video]
                  .concat(mpvProc.forLock ? ["lock"] : [])
          mpvProc.running = true
      }
      Process {
          id: mpvProc
          property string video: ""
          property bool forLock: false
          property bool again: false
          onExited: exitCode => {
              if (!mpvProc.forLock)
                  bgRoot.mpvOverride = "none"
              else if (exitCode === 0)
                  bgRoot.mpvOverride = mpvProc.video
              else
                  bgRoot.lockVideoFailed = true
              if (mpvProc.again) {
                  mpvProc.again = false
                  Qt.callLater(bgRoot.syncMpv)
              }
          }
      }
      Connections {
          target: GlobalStates
          function onScreenLockedChanged() {
              if (!GlobalStates.screenLocked) bgRoot.lockVideoFailed = false
          }
      }

      // Nothing the shell listens to tells it a screen went off, so while
      // locked with a video the monitor list is refreshed every 2s instead.
      Timer {
          running: GlobalStates.screenLocked && bgRoot.mpvVideo !== ""
          interval: 2000
          repeat: true
          onTriggered: HyprlandData.updateMonitors()
      }
    '';
  };

  # ── Bar islands that follow the wallpaper.
  #
  # The palette comes from the wallpaper's dominant colour, so on a mostly
  # black wallpaper every island is the same near-black even where a corner
  # of the picture is bright. In the island style (bar.cornerStyle 2) each
  # BarGroup now paints the wallpaper that is actually behind it instead:
  #
  # WallpaperRegions (a new service) shrinks the wallpaper to a 96x54 colour
  # grid once per wallpaper change — a still: a video contributes the same
  # frame Background.qml shows before it goes live, and nothing is sampled
  # while it plays. Each BarGroup works out where it sits on its screen from
  # its own geometry and its window's anchors, so any bar edge (top, bottom,
  # the vertical bar left or right) and any reflow is followed without a
  # fixed left/centre/right split. It samples three points along its length
  # into a gradient, so the segments of one pill run into each other.
  #
  # Each sample is mixed 50% into the theme's layer0 and then pushed away from
  # the text colour (darker on a dark theme) until the theme's text keeps
  # 4.5:1 on it — measured on what is actually seen: the island at 65%
  # opacity over the wallpaper behind it. If no amount of darkening gets
  # there, the island gets more opaque instead. The widgets keep the global
  # text colours; only the island backgrounds change, so none of them needs
  # patching. A white corner therefore gives a grey island, not a white one.
  #
  # The 65% needs the bar's blur rule to accept it: rules.lua gives every
  # quickshell layer ignore_alpha 0.79, which would leave these islands
  # unblurred; the bar layers get 0.3 below (see IIRULES). They also get
  # xray off: xray blurs the blur cache, which is off under a video, so the
  # islands were blurring black, not the wallpaper.
  barRegionsGrid = pkgs.writeShellScript "ii-bar-regions-grid" ''
    set -eu
    ${pkgs.imagemagick}/bin/magick identify -ping -format '%w %h\n' "$1[0]"
    ${pkgs.imagemagick}/bin/magick "$1[0]" -strip -background black -alpha remove -alpha off \
      -resize "$2!" -depth 8 -compress none ppm:-
  '';

  barIslandQml = {
    service = pkgs.writeText "WallpaperRegions.qml" ''
      pragma Singleton
      pragma ComponentBehavior: Bound

      import QtQuick
      import Quickshell
      import Quickshell.Io
      import qs.modules.common

      // The wallpaper as a coarse colour grid, so the bar's islands can take on
      // the colour of what is behind them (NixOS config, ii-session.nix).
      Singleton {
          id: root

          readonly property int gridWidth: 96
          readonly property int gridHeight: 54

          // Always a still: a video contributes its frame, as Background.qml does.
          readonly property string source: {
              const path = Config.options.background.wallpaperPath || "";
              return Images.isVideoByName(path) ? Images.videoFramePath(path) : path;
          }

          property bool ready: false
          property real imageAspect: 16 / 9
          property var cells: [] // row-major r, g, b in 0..1
          property string loadingSource: ""
          property bool pending: false
          property int attempts: 0

          onSourceChanged: {
              root.attempts = 0;
              root.load();
          }
          Component.onCompleted: root.load()

          function load() {
              if (!root.source) {
                  root.ready = false;
                  return;
              }
              if (grid.running) {
                  root.pending = true;
                  return;
              }
              root.loadingSource = root.source;
              grid.exec(["${barRegionsGrid}", root.source, root.gridWidth + "x" + root.gridHeight]);
          }

          // First line "width height" of the original, then a plain PPM.
          function parse(text) {
              if (root.loadingSource !== root.source)
                  return; // superseded; pending reloads it
              const lines = text.split("\n").filter(line => !line.startsWith("#"));
              const size = (lines.shift() || "").trim().split(/\s+/).map(Number);
              const tokens = lines.join(" ").trim().split(/\s+/);
              const count = root.gridWidth * root.gridHeight * 3;
              const valid = size.length === 2 && size[0] > 0 && size[1] > 0
                  && tokens[0] === "P3"
                  && Number(tokens[1]) === root.gridWidth
                  && Number(tokens[2]) === root.gridHeight
                  && tokens.length >= 4 + count;
              if (!valid) {
                  // A new video's frame can land a moment after the config does.
                  if (++root.attempts <= 10)
                      retry.restart();
                  else
                      root.ready = false;
                  return;
              }
              const max = Number(tokens[3]) || 255;
              const cells = new Array(count);
              for (let i = 0; i < count; i++)
                  cells[i] = Number(tokens[4 + i]) / max;
              root.imageAspect = size[0] / size[1];
              root.cells = cells;
              root.ready = true;
          }

          // Mean colour of a rectangle of a screen, in that screen's logical
          // pixels, with the wallpaper laid out as Background.qml and mpvpaper
          // (panscan=1.0) lay it out: scaled to cover, centred, cropped.
          function regionColor(rect, screenWidth, screenHeight) {
              const cells = root.cells;
              if (cells.length < root.gridWidth * root.gridHeight * 3 || screenWidth <= 0 || screenHeight <= 0)
                  return Qt.rgba(0, 0, 0, 1);
              let u0 = rect.x / screenWidth, u1 = (rect.x + rect.width) / screenWidth;
              let v0 = rect.y / screenHeight, v1 = (rect.y + rect.height) / screenHeight;
              const screenAspect = screenWidth / screenHeight;
              if (root.imageAspect > screenAspect) {
                  const f = screenAspect / root.imageAspect;
                  u0 = 0.5 - f / 2 + u0 * f;
                  u1 = 0.5 - f / 2 + u1 * f;
              } else {
                  const f = root.imageAspect / screenAspect;
                  v0 = 0.5 - f / 2 + v0 * f;
                  v1 = 0.5 - f / 2 + v1 * f;
              }
              const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
              const x0 = clamp(Math.floor(u0 * root.gridWidth), 0, root.gridWidth - 1);
              const x1 = clamp(Math.ceil(u1 * root.gridWidth) - 1, x0, root.gridWidth - 1);
              const y0 = clamp(Math.floor(v0 * root.gridHeight), 0, root.gridHeight - 1);
              const y1 = clamp(Math.ceil(v1 * root.gridHeight) - 1, y0, root.gridHeight - 1);
              let r = 0, g = 0, b = 0, n = 0;
              for (let y = y0; y <= y1; y++) {
                  for (let x = x0; x <= x1; x++) {
                      const i = (y * root.gridWidth + x) * 3;
                      r += cells[i];
                      g += cells[i + 1];
                      b += cells[i + 2];
                      n++;
                  }
              }
              return Qt.rgba(r / n, g / n, b / n, 1);
          }

          function luminance(c) {
              const lin = v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
              return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
          }

          function contrast(a, b) {
              const la = root.luminance(a), lb = root.luminance(b);
              return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
          }

          // a towards b by t
          function mix(a, b, t) {
              return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
          }

          // An island over `sample`: `tint` of the sample mixed into `base`,
          // at `opacity`, pushed away from `foreground` until the foreground
          // keeps `minContrast` on the composite (island over the wallpaper);
          // then more opaque if that is not enough.
          function islandColor(sample, base, foreground, tint, opacity, minContrast) {
              const tinted = root.mix(base, sample, tint);
              const away = root.luminance(foreground) > root.luminance(base) ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1);
              for (const alpha of [opacity, (opacity + 1) / 2, 1]) {
                  for (let step = 0; step <= 10; step++) {
                      const c = root.mix(tinted, away, step / 10);
                      if (root.contrast(root.mix(sample, c, alpha), foreground) >= minContrast)
                          return Qt.rgba(c.r, c.g, c.b, alpha);
                  }
              }
              return Qt.rgba(base.r, base.g, base.b, 1);
          }

          Process {
              id: grid
              stdout: StdioCollector {
                  onStreamFinished: root.parse(this.text)
              }
              onRunningChanged: {
                  if (!running && root.pending) {
                      root.pending = false;
                      Qt.callLater(root.load);
                  }
              }
          }

          Timer {
              id: retry
              interval: 1000
              onTriggered: root.load()
          }
      }
    '';

    # BarGroup.qml, after bgColor.
    props = pkgs.writeText "ii-bar-island-props.qml" ''

      // Wallpaper-adaptive islands (NixOS config, ii-session.nix): in the island
      // style the background is the wallpaper behind it, sampled at three points
      // along the group, tinted into the theme and kept readable. See
      // WallpaperRegions.
      readonly property bool islandAdaptive: Config.options.bar.cornerStyle === 2
          && root.paintBackground
          && Config.options?.bar.borderless !== "transparent"
          && WallpaperRegions.ready
      // Where the island sits on its screen. Summed up the parent chain rather
      // than mapToItem() so the binding follows every x/y above it: a row
      // reflowing, the bar sliding in, the bar moving to another edge.
      readonly property rect islandScreenRect: {
          const win = root.QsWindow.window;
          if (!root.islandAdaptive || !win || !win.screen)
              return Qt.rect(0, 0, 0, 0);
          let x = 0, y = 0;
          for (let item = islandBackground; item; item = item.parent) {
              x += item.x;
              y += item.y;
          }
          const sw = win.screen.width, sh = win.screen.height;
          const edges = win.anchors, margins = win.margins;
          const wx = !edges || edges.left ? (margins?.left ?? 0)
              : edges.right ? sw - win.width - (margins?.right ?? 0) : (sw - win.width) / 2;
          const wy = !edges || edges.top ? (margins?.top ?? 0)
              : edges.bottom ? sh - win.height - (margins?.bottom ?? 0) : (sh - win.height) / 2;
          return Qt.rect(wx + x, wy + y, islandBackground.width, islandBackground.height);
      }
      readonly property var islandStops: {
          const r = root.islandScreenRect;
          const screen = root.QsWindow.window?.screen;
          if (!root.islandAdaptive || !screen || r.width <= 0 || r.height <= 0 || WallpaperRegions.cells.length === 0)
              return [];
          const base = Appearance.colors.colLayer0Base;
          const foreground = Appearance.colors.colOnLayer0;
          const stops = [];
          for (let i = 0; i < 3; i++) {
              const part = root.vertical
                  ? Qt.rect(r.x, r.y + r.height * i / 3, r.width, r.height / 3)
                  : Qt.rect(r.x + r.width * i / 3, r.y, r.width / 3, r.height);
              stops.push(WallpaperRegions.islandColor(
                  WallpaperRegions.regionColor(part, screen.width, screen.height),
                  base, foreground, 0.5, 0.65, 4.5));
          }
          return stops;
      }
      readonly property bool islandPainted: root.islandStops.length === 3
    '';

    # BarGroup.qml, before `background`, so it is drawn under it: background
    # keeps the segmented border and goes transparent while this is painted.
    background = pkgs.writeText "ii-bar-island-background.qml" ''

      Rectangle {
          id: islandBackground
          anchors.fill: background
          visible: root.islandPainted
          topLeftRadius: background.topLeftRadius
          topRightRadius: background.topRightRadius
          bottomLeftRadius: background.bottomLeftRadius
          bottomRightRadius: background.bottomRightRadius
          gradient: Gradient {
              orientation: root.vertical ? Gradient.Vertical : Gradient.Horizontal
              GradientStop {
                  position: 1 / 6
                  color: root.islandStops[0] ?? "transparent"
                  Behavior on color {
                      animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                  }
              }
              GradientStop {
                  position: 0.5
                  color: root.islandStops[1] ?? "transparent"
                  Behavior on color {
                      animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                  }
              }
              GradientStop {
                  position: 5 / 6
                  color: root.islandStops[2] ?? "transparent"
                  Behavior on color {
                      animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                  }
              }
          }
      }
    '';
  };

  # switchwall.sh's video branch, before and after. Upstream wrote the config
  # first, then started mpvpaper, then extracted the frame and wrote
  # thumbnailPath — so the shell saw the new wallpaper before the video was
  # running or its frame existed. Now the frame comes first, then mpvpaper,
  # then thumbnailPath and wallpaperPath, in the order the shell reads them.
  # Each mpvpaper also opens the IPC socket mpvpaperCtl talks to, and plays
  # what videoProxy hands back; the config keeps the original's path, which
  # is what the selector, the frame and the restore script go by.
  #
  # Replaced as one block rather than line by line because the reorder moves
  # lines across each other; the old text is spelled out so any upstream change
  # to it fails the build instead of applying half a patch.
  videoSwitch = {
    old = pkgs.writeText "ii-video-switch-old" ''
      if [[ -z "$colors_only_flag" ]]; then
          set_wallpaper_path "$imgpath"

          local video_path="$imgpath"
          monitors=$(hyprctl monitors -j | jq -r '.[] | .name')
          for monitor in $monitors; do
              mpvpaper -o "$VIDEO_OPTS" "$monitor" "$video_path" &
              sleep 0.1
          done
      fi

      thumbnail="$THUMBNAIL_DIR/$(basename "$imgpath").jpg"
      ffmpeg -y -i "$imgpath" -vframes 1 "$thumbnail" 2>/dev/null

      if [[ -z "$colors_only_flag" ]]; then
          set_thumbnail_path "$thumbnail"
      fi
    '';
    new = pkgs.writeText "ii-video-switch-new" ''
      thumbnail="$(${videoFrame} "$imgpath")"

      if [[ -z "$colors_only_flag" ]]; then
          local video_path="$imgpath"
          local play_path
          play_path="$(${videoProxy}/bin/ii-video-proxy "$imgpath")" || play_path="$imgpath"
          monitors=$(hyprctl monitors -j | jq -r '.[] | .name')
          for monitor in $monitors; do
              mpvpaper -o "$VIDEO_OPTS input-ipc-server=$XDG_RUNTIME_DIR/mpvpaper-$monitor.sock" "$monitor" "$play_path" &
              sleep 0.1
          done
          ${blurCache false}

          set_thumbnail_path "$thumbnail"
          set_wallpaper_path "$imgpath"
      fi
    '';
  };

  # ── Blur over a live wallpaper.
  #
  # Measured on this machine with a 30fps 1080p video: mpv dropped ~16 of
  # every 30 frames, the same in every sync mode, and with framedrop=no the
  # video ran at half speed instead. Not one frame could be drawn when mpv
  # had it ready; every one waited on Hyprland's frame callback, which came
  # ~14 times a second on a 120Hz output. The compositor itself was the
  # bottleneck, which is also why the whole desktop felt slow and why the same
  # video in a browser did not: a browser window does not sit *under* the blur.
  # With blur off, 0 drops. The two things responsible, found by turning them
  # off one at a time (drops per 5s: 78 as shipped):
  #
  # rules.lua blurs every quickshell:* layer, including three where the blur
  # can never be seen: the shell's own wallpaper window (full screen, opaque
  # over a still wallpaper and transparent but for the widgets over a video),
  # the 2px screen-frame strips and the screen corners. Excluding the
  # wallpaper window alone took it to 18, all three to 10. Nothing visible is
  # lost with a still wallpaper either, so they are excluded outright.
  #
  # new_optimizations caches the blurred background (background + bottom
  # layers) so that blurred surfaces above it sample the cache instead of
  # blurring again. The right trade for a still wallpaper, the wrong one for a
  # video: the cache goes stale every video frame, so every frame paid for a
  # full-screen blur per monitor however little of it anything blurred was
  # over. Off on top of the rules above: 0 drops on both monitors, with foot
  # and Dolphin tiled over the video and translucent (inactive_opacity 0.9).
  # It is off only while a video is set — switchwall.sh flips it when the
  # wallpaper changes, and general.lua re-derives it on every config load from
  # the restore script, the one file that records whether a video is set.
  # With it off, xray has no effect: a translucent floating window blurs the
  # windows behind it as well as the wallpaper.
  blurCache = on: "hyprctl eval 'hl.config({ decoration = { blur = { new_optimizations = ${lib.boolToString on} } } })' >/dev/null";

  # ── The merged, patched config tree.
  #
  # ii supplies the whole install (hypr config, scripts, matugen templates, the
  # app configs); end4-pC is dropped in beside ii's quickshell config as a
  # second config root, which is exactly how its README says to install it.
  dots = pkgs.runCommand "illogical-impulse-nixos" { } ''
    cp -r ${inputs.dots-hyprland}/dots $out
    chmod -R u+w $out

    mkdir -p $out/.config/quickshell/${qsConfig}
    cp -r ${inputs.end4-pc}/. $out/.config/quickshell/${qsConfig}/
    chmod -R u+w $out/.config/quickshell/${qsConfig}

    # Documentation and the translation tooling: 33MB of screenshots and a set
    # of dev scripts that only ever run by hand from a checkout.
    rm -rf $out/.config/quickshell/${qsConfig}/screenshots
    rm -rf $out/.config/quickshell/${qsConfig}/translations/tools
    rm -f  $out/.config/quickshell/${qsConfig}/README*.md
    rm -f  $out/.config/quickshell/${qsConfig}/LICENSE

    # ── The submodule check.
    #
    # dots/.config/quickshell/ii/modules/common/widgets/shapes is a git
    # submodule (rounded-polygon-qmljs). MaterialCookie.qml imports two files
    # from it by relative path, and a missing QML import fails at runtime with
    # nothing but a warning in the shell's log — so fail the build instead.
    # This is what submodules=1 on the flake input is there for.
    if [ ! -f $out/.config/quickshell/ii/modules/common/widgets/shapes/material-shapes.js ]; then
      echo "dots-hyprland: shapes submodule is empty — the flake input lost submodules=1" >&2
      exit 1
    fi

    # ── Fonts.
    #
    # Both shells default to "Google Sans Flex", which is Google's brand font
    # and is in neither nixpkgs nor pkgs.google-fonts (that ships GoogleSansCode,
    # a different, monospace family). Left alone, fontconfig falls back to a
    # generic sans and every panel renders wrong. Rubik is ii's own previous
    # default and is packaged, so it is the stand-in.
    #
    # "JetBrains Mono NF" is the Arch AUR family name; the nerd-fonts package in
    # nixpkgs registers it as "JetBrainsMono NF" (no space). Same font, and the
    # icon glyphs come back with the exact name.
    find $out -name '*.qml' -print0 | xargs -0 sed -i \
      -e 's/"Google Sans Flex"/"Rubik"/g' \
      -e 's/"JetBrains Mono NF"/"JetBrainsMono NF"/g'

    # ── The Python venv.
${python.patch}
    # ── FHS paths.
    #
    # start_geoclue_agent.sh already probes /run/current-system/sw, so it works
    # unpatched — but only if the demo agent happens to be in the system
    # profile. Point it at the store path instead so it cannot silently miss.
    sed -i 's|/usr/libexec/geoclue-2.0/demos/agent|${pkgs.geoclue2-with-demo-agent}/libexec/geoclue-2.0/demos/agent|' \
      $out/.config/hypr/hyprland/scripts/start_geoclue_agent.sh

    # The keyboard-layout picker reads the X11 rules list to name layouts.
    sed -i 's|"/usr/share/X11/xkb/rules/base.lst"|"${pkgs.xkeyboard_config}/share/X11/xkb/rules/base.lst"|' \
      $out/.config/quickshell/ii/services/HyprlandXkb.qml

    # env.lua prepends the FHS share dirs to XDG_DATA_DIRS. They don't exist
    # here, and xdg_data_dirs_old already carries the NixOS ones.
    sed -i 's|:/usr/local/share:/usr/share:|:|' $out/.config/hypr/hyprland/env.lua

${terminals.patch}
${microtex.patch}
    # ── Icon theme, for the half of the colour pipeline that never ran.
    #
    # kde-material-you-colors switches the icon theme with the light/dark mode
    # too, via plasma-changeicons (plasma_utils.py:89-96) — see plasmaTools
    # above for why that binary now exists at all. The themes upstream names
    # here are breeze-plus / breeze-plus-dark, which is the one dependency
    # still packaged nowhere, so the call would find its tool and then fail on
    # a missing theme. breeze and breeze-dark ship in kdePackages.breeze-icons,
    # already in home.packages below, and are what breeze-plus forks anyway.
    #
    # This is the seed only. config.conf is in mutablePaths, so an install
    # that already has one keeps it — the live file has to be edited by hand,
    # which is the same bargain every other entry in that list makes.
    substituteInPlace $out/.config/kde-material-you-colors/config.conf \
      --replace-fail 'iconslight = breeze-plus' 'iconslight = breeze' \
      --replace-fail 'iconsdark = breeze-plus-dark' 'iconsdark = breeze-dark'

    # ── Which shell starts.
    sed -i 's|hl.env("qsConfig", "ii")|hl.env("qsConfig", "${qsConfig}")|' \
      $out/.config/hypr/hyprland/variables.lua
    grep -q 'hl.env("qsConfig", "${qsConfig}")' $out/.config/hypr/hyprland/variables.lua

    # ── SUPER+I opens Settings in whichever shell is running.
    #
    # end4-pC's Settings is an overlay panel reached over IPC
    # (modules/ii/settings/Settings.qml:170); its README asks for SUPER+Escape.
    # SUPER+I is used instead because ii already binds it to "App: Settings
    # app" (keybinds.lua:354) and that binding is dead under end4-pC — its
    # first candidate is `qs -p .../$qsConfig/settings.qml`, a file end4-pC
    # doesn't have, so today it falls through to systemsettings.
    #
    # Hyprland fires every bind that matches, so both lines are needed and both
    # have to be inert in the other shell: the global is a no-op under ii (no
    # such IPC handler there), and the exec is guarded on the settings.qml that
    # only ii ships. Exactly one thing happens either way.
    #
    # SUPER+ALT+S was the first idea and is not free — keybinds.lua:241 uses it
    # for "Window: Send to scratchpad".
    sed -i 's|^hl.bind("SUPER + I", hl.dsp.exec_cmd(settingsApp), { description = "App: Settings app" })$|hl.bind("SUPER + I", hl.dsp.global("quickshell:settingsToggle"), { description = "App: Settings" })\nhl.bind("SUPER + I", hl.dsp.exec_cmd("[ -f $HOME/.config/quickshell/$qsConfig/settings.qml ] \&\& " .. settingsApp))|' \
      $out/.config/hypr/hyprland/keybinds.lua
    grep -q 'quickshell:settingsToggle' $out/.config/hypr/hyprland/keybinds.lua

    # ── SUPER+W is unbound.
    #
    # Upstream opens the browser on it; asked to have it removed outright
    # rather than moved. Checked before and after so an upstream rewording
    # fails the build instead of leaving the bind silently in place.
    grep -q '^hl.bind("SUPER + W", hl.dsp.exec_cmd(browser),' $out/.config/hypr/hyprland/keybinds.lua
    sed -i '/^hl.bind("SUPER + W", hl.dsp.exec_cmd(browser),/d' \
      $out/.config/hypr/hyprland/keybinds.lua
    [ "$(grep -c '"SUPER + W"' $out/.config/hypr/hyprland/keybinds.lua)" = "0" ] || exit 1

    # ── Capture destinations.
    #
    # end4-pC is the shell that runs by default; ii gets the same treatment
    # where it has the same knob, without failing the build if it does not.
    substituteInPlace $out/.config/quickshell/${qsConfig}/modules/common/Config.qml \
      --replace-fail \
        'property string savePath: "" // only copy to clipboard when empty' \
        'property string savePath: "${screenshotDir}"' \
      --replace-fail \
        'property string savePath: Directories.videos.replace("file://","") // strip "file://"' \
        'property string savePath: "${recordingDir}"'

    for f in $out/.config/quickshell/ii/modules/common/Config.qml; do
      [ -e "$f" ] || continue
      sed -i \
        -e 's|property string savePath: "" // only copy to clipboard when empty|property string savePath: "${screenshotDir}"|' \
        -e 's|property string savePath: Directories.videos.replace("file://","") // strip "file://"|property string savePath: "${recordingDir}"|' \
        "$f"
    done

    # ── Screenshot and recording keys, aligned with caelestia.
    #
    # Only the two that were reversed. caelestia binds SUPER+ALT+R to
    # "fullscreen, with sound" and SUPER+SHIFT+ALT+R to "region"; ii has them
    # exactly the other way round, which is the pair that actually breaks
    # muscle memory. Everything else in the capture group already matches, and
    # ii's region selector is deliberately left alone — it opens a toolbar
    # (copy / edit via swappy / search / OCR / record / record with sound) that
    # caelestia has no equivalent for, so flattening it would trade down.
    #
    # Each anchor carries its action, so the two rewrites cannot collide: after
    # the first two lines become SUPER+SHIFT+ALT+R they no longer match the
    # third pattern, which names a different command.
    substituteInPlace $out/.config/hypr/hyprland/keybinds.lua \
      --replace-fail \
        'hl.bind("SUPER + ALT + R", hl.dsp.global("quickshell:regionRecord"), { locked = true })' \
        'hl.bind("SUPER + SHIFT + ALT + R", hl.dsp.global("quickshell:regionRecord"), { locked = true })' \
      --replace-fail \
        'hl.bind("SUPER + ALT + R", hl.dsp.exec_cmd(qsIsAlive .. " || " .. qsScripts .. "/videos/record.sh"), { locked = true })' \
        'hl.bind("SUPER + SHIFT + ALT + R", hl.dsp.exec_cmd(qsIsAlive .. " || " .. qsScripts .. "/videos/record.sh"), { locked = true })' \
      --replace-fail \
        'hl.bind("SUPER + SHIFT + ALT + R", hl.dsp.exec_cmd(qsScripts .. "/videos/record.sh --fullscreen --sound"),' \
        'hl.bind("SUPER + ALT + R", hl.dsp.exec_cmd(qsScripts .. "/videos/record.sh --fullscreen --sound"),'

    # Print saves a file as well as copying, and CTRL+Print follows it to the
    # same directory instead of ~/Pictures/Screenshots.
    substituteInPlace $out/.config/hypr/hyprland/keybinds.lua \
      --replace-fail \
        'hl.bind("Print", hl.dsp.exec_cmd(grimhyprctl .. " - | wl-copy"),' \
        'hl.bind("Print", hl.dsp.exec_cmd("${printScreenshot}"),' \
      --replace-fail \
        'mkdir -p $(xdg-user-dir PICTURES)/Screenshots && ' \
        'mkdir -p ${screenshotDir} && '

    # ── Lid and idle (see displayPower above).
    #
    # Upstream ships the lid bind commented out, as a suspend. It becomes the
    # panel-off/on pair instead; locked so it still fires on the lock screen.
    sed -i 's|^-- hl.bind("switch:on:Lid Switch", .*$|hl.bind("switch:on:Lid Switch", hl.dsp.exec_cmd("${displayPower}/bin/ii-display-power lid-close"), { locked = true }) -- # [hidden]\nhl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd("${displayPower}/bin/ii-display-power lid-open"), { locked = true }) -- # [hidden]|' \
      $out/.config/hypr/hyprland/keybinds.lua
    grep -q '^hl.bind("switch:off:Lid Switch"' $out/.config/hypr/hyprland/keybinds.lua

    cp ${hypridleConf} $out/.config/hypr/hypridle.conf

    # The shell's own battery suspend (18% in this config.json) would put the
    # machine to sleep before it ever reached UPower's 12% poweroff, and a
    # suspended machine checks nothing — it would drain to zero asleep. Its
    # low/critical notifications are kept; only the suspend goes. As with the
    # capture paths, this is the QML default: an existing config.json that
    # already says true still wins.
    substituteInPlace $out/.config/quickshell/${qsConfig}/modules/common/Config.qml \
      --replace-fail 'property bool automaticSuspend: true' 'property bool automaticSuspend: false'
    for f in $out/.config/quickshell/ii/modules/common/Config.qml; do
      [ -e "$f" ] || continue
      sed -i 's|property bool automaticSuspend: true|property bool automaticSuspend: false|' "$f"
    done

    # ── Light/dark follows the wallpaper (see autoLightDark above).
    #
    # Applied to both shells: each carries its own copy of switchwall.sh.
    for f in $out/.config/quickshell/*/scripts/colors/switchwall.sh; do
      [ -e "$f" ] || continue
      # Inserted before upstream's own block rather than replacing it: with
      # auto off the helper echoes $mode_flag back unchanged and the original
      # precedence below runs exactly as written.
      substituteInPlace "$f" --replace-fail \
        'if [[ -z "$mode_flag" ]]; then' \
        'mode_flag="$(${autoLightDark} "$imgpath" "$mode_flag")"
        if [[ -z "$mode_flag" ]]; then'

      # ── And the write that decision turns into: dconf, not gsettings.
      #
      # pre_process() is the only thing that tells the rest of the machine
      # what mode this wallpaper chose — the portal, GTK, Qt and session A all
      # read org.gnome.desktop.interface color-scheme and nothing else. It
      # spelled that write as `gsettings set`, which on a session with no
      # schemas on XDG_DATA_DIRS exits 1 and prints "No schemas installed" to
      # a stderr nobody reads. ../modules/hyprland-desktop.nix now puts the
      # schemas there, so this is no longer load-bearing — but the failure it
      # covers took months to notice precisely because it was silent, and
      # dconf removes the dependency rather than satisfying it. Same database,
      # same D-Bus change notification, no schema lookup; it is what
      # ../home/qt.nix and the autoLightDark helper above already use, for the
      # reasons spelled out there.
      #
      # sed rather than substituteInPlace, and on one line at a time: the two
      # writes sit inside an if/elif whose common indentation Nix would strip
      # from a multi-line anchor. The capture carries the value, so one
      # expression covers prefer-dark and prefer-light without naming either.
      #
      # dconf takes a GVariant, so a string value needs its quotes inside the
      # argument: "'prefer-dark'", not 'prefer-dark'.
      before=$(grep -c "gsettings set org.gnome.desktop.interface" "$f" || true)
      [ "$before" = "4" ] || {
        echo "pre_process: expected 4 gsettings writes, found $before" >&2
        exit 1
      }
      sed -i \
        -e "s|gsettings set org\.gnome\.desktop\.interface color-scheme '\(.*\)'|${pkgs.dconf}/bin/dconf write /org/gnome/desktop/interface/color-scheme \"'\1'\"|" \
        -e "s|gsettings set org\.gnome\.desktop\.interface gtk-theme '\(.*\)'|${pkgs.dconf}/bin/dconf write /org/gnome/desktop/interface/gtk-theme \"'\1'\"|" \
        "$f"
      [ "$(grep -c "gsettings set org.gnome.desktop.interface" "$f" || true)" = "0" ] || exit 1
      [ "$(grep -c "dconf write /org/gnome/desktop/interface" "$f" || true)" = "4" ] || exit 1
    done

    # ── Video wallpapers (see videoFrame, mpvpaperCtl and videoQml above).
    #
    # end4-pC only: it is the shell that runs, and ii's copies of these files
    # have drifted from it (its switchwall.sh has no colors-only mode), so one
    # set of anchors cannot cover both.
    qs=$out/.config/quickshell/${qsConfig}

    # Inserts a snippet after a line that must occur exactly once, re-indented
    # to $4. Matched as a whole literal line, so QML's brackets and quotes
    # need no escaping; cat-into rather than mv so the file keeps its mode.
    insert_after() {
      [ "$(grep -cxF -- "$2" "$1" || true)" = "1" ] || {
        echo "$1: expected exactly one line: $2" >&2
        exit 1
      }
      sed "s/^./$4&/" "$3" > $TMPDIR/snippet
      awk -v anchor="$2" -v snippet=$TMPDIR/snippet \
        '{ print } $0 == anchor { while ((getline l < snippet) > 0) print l; close(snippet) }' \
        "$1" > $TMPDIR/inserted
      cat $TMPDIR/inserted > "$1"
    }

    # Case. Upstream tests for a video by lowercase extension, but the
    # selector's folder model is case-insensitive, so a .MP4 would be listed
    # and then handed down the image path — matugen reading a video. One
    # spelling everywhere, the regex the rest of end4-pC (DesktopMenu,
    # BackgroundConfig, QuickConfig) already uses; switchwall.sh and the
    # thumbnail pass below lowercase too.
    before=$({ grep -rF 'endsWith(".mov")' $qs --include='*.qml' || true; } | wc -l)
    [ "$before" = "3" ] || { echo "video checks: expected 3 endsWith chains, found $before" >&2; exit 1; }
    grep -rlZF 'endsWith(".mov")' $qs --include='*.qml' | xargs -0 sed -i \
      's#\([A-Za-z_][A-Za-z0-9_.]*\)\.endsWith("\.mp4") || \1\.endsWith("\.webm") || \1\.endsWith("\.mkv") || \1\.endsWith("\.avi") || \1\.endsWith("\.mov")#/\\.(mp4|webm|mkv|avi|mov)$/i.test(\1)#g'
    [ "$({ grep -rF 'endsWith(".mov")' $qs --include='*.qml' || true; } | wc -l)" = "0" ] || exit 1
    [ "$({ grep -rF '/\.(mp4|webm|mkv|avi|mov)$/i.test(' $qs --include='*.qml' || true; } | wc -l)" -ge "3" ] || exit 1

    insert_after $qs/modules/common/Images.qml \
      '    readonly property list<string> validImageExtensions: ["jpg", "jpeg", "png", "webp", "avif", "bmp", "tif", "tiff", "svg"]' \
      ${videoQml.images} '    '

    # The selector: list videos, show their tiles as thumbnails, and have a
    # video tile ask for its thumbnail rather than sit on a file icon.
    substituteInPlace $qs/services/Wallpapers.qml \
      --replace-fail '    readonly property list<string> extensions: [ // TODO: add videos' \
                     '    readonly property list<string> extensions: [' \
      --replace-fail '"jpg", "jpeg", "png", "webp", "avif", "bmp", "svg"' \
                     '"jpg", "jpeg", "png", "webp", "avif", "bmp", "svg", "mp4", "webm", "mkv", "avi", "mov"'
    insert_after $qs/services/Wallpapers.qml \
      '    property string confirmedPath: ""  // Holds confirmed path until config catches up' \
      ${videoQml.wallpapers} '    '

    substituteInPlace $qs/modules/ii/wallpaperSelector/WallpaperDirectoryItem.qml \
      --replace-fail 'Images.isValidImageByName(fileModelData.fileName) : false' \
                     '(Images.isValidImageByName(fileModelData.fileName) || Images.isVideoByName(fileModelData.fileName)) : false'
    insert_after $qs/modules/ii/wallpaperSelector/WallpaperDirectoryItem.qml \
      '                        generateThumbnail: false' \
      ${videoQml.tile} '                        '

    # The thumbnail pass. It skipped videos outright; it now thumbnails their
    # frame, and makes sure the full-size frame exists for the preview. This is
    # the pass that actually runs here: its Python sibling, tried first, dies
    # on import (no GnomeDesktop typelib in the venv), so every thumbnail comes
    # from this script. GIFs are still skipped, as upstream.
    substituteInPlace $qs/scripts/thumbnails/generate-thumbnails-magick.sh \
      --replace-fail '        *.gif|*.mp4|*.webm|*.mkv|*.avi|*.mov)' '        *.gif)' \
      --replace-fail '    local encoded_path' '    local src_image="$abs_path"
    case "''${abs_path,,}" in
        *.mp4|*.webm|*.mkv|*.avi|*.mov) src_image="$(${videoFrame} "$abs_path")" || return 0 ;;
    esac
    local encoded_path' \
      --replace-fail 'magick "$abs_path" -resize' 'magick "$src_image" -resize'

    # The background: a video's picture is its own frame, not whatever
    # thumbnailPath the config holds (that is the *applied* wallpaper's, so a
    # previewed video showed the wrong one), and the window only goes
    # transparent over the video that is actually playing.
    #
    # Of the three upstream reveals, the one at the end of a transition goes
    # through the delay; startup and unlock stay immediate, as mpvpaper has
    # been running all along by then.
    B=$qs/modules/ii/background/Background.qml
    substituteInPlace $B \
      --replace-fail 'wallpaperIsVideo ? Config.options.background.thumbnailPath : bgRoot.effectiveWallpaperPath' \
                     'wallpaperIsVideo ? Images.videoFramePath(bgRoot.effectiveWallpaperPath) : bgRoot.effectiveWallpaperPath' \
      --replace-fail 'bgRoot.videoRevealed = bgRoot.wallpaperIsVideo' 'bgRoot.videoRevealed = bgRoot.videoIsLive' \
      --replace-fail '                if (!bgRoot.wallpaperIsVideo) return' '                if (!bgRoot.videoIsLive) return' \
      --replace-fail '                bgRoot.videoRevealed = true' '                videoRevealDelay.restart()' \
      --replace-fail 'wallpaperIsVideo: bgRoot.wallpaperIsVideo' 'wallpaperIsVideo: bgRoot.videoIsLive' \
      --replace-fail 'showBlur && !bgRoot.wallpaperIsVideo' 'showBlur && !bgRoot.videoIsLive'
    [ "$(grep -c '^                bgRoot.videoRevealed = bgRoot.videoIsLive$' $B)" = "1" ] || {
      echo "Background.qml: expected one reveal at the end of the transition" >&2
      exit 1
    }
    sed -i 's/^                bgRoot.videoRevealed = bgRoot.videoIsLive$/                if (bgRoot.videoIsLive) videoRevealDelay.restart()/' $B
    [ "$(grep -c 'bgRoot.videoRevealed = bgRoot.videoIsLive' $B)" = "2" ] || exit 1
    insert_after $B '        property bool videoRevealed: false' ${videoQml.background} '        '

    # The overview's workspace cards draw the wallpaper as-is, so with a video
    # they loaded the .mp4 as an image, failed, and showed the card's colour —
    # which upstream left as a debugging "red". The card gets the video's
    # frame, and a theme colour behind it for the moment it is loading.
    #
    # sourceSize because there are twenty cards (maxWorkspaces), each the
    # wallpaper at overview.scale (0.18 here, ~346x194), and without it they
    # were fed the full image — 1080p at best, the 16MB Escoffier PNG at
    # worst. They share one url, so at the cards' size it is one small decode.
    O=$qs/modules/ii/overview/NiriOverview.qml
    substituteInPlace $O \
      --replace-fail '                        color: "red"' '                        color: Appearance.colors.colLayer1' \
      --replace-fail '                            source: Config.options.background.wallpaperPath' \
                     '                            source: Images.isVideoByName(Config.options.background.wallpaperPath) ? Images.videoFramePath(Config.options.background.wallpaperPath) : Config.options.background.wallpaperPath
                            sourceSize: Qt.size(root.monitorW * root.scale, root.wsHeight)'
    [ "$(grep -c 'Images.videoFramePath' $O)" = "1" ] || exit 1

    # Settings' Desktop/Lockscreen pair and the desktop menu's wallpaper
    # strip picture a video by thumbnailPath, which is the *desktop* video's
    # frame — so a lock screen video, or any other video in the strip, showed
    # the desktop's. Each gets its own frame.
    for f in $qs/modules/ii/settings/pages/BackgroundConfig.qml $qs/modules/ii/desktopMenu/DesktopMenu.qml; do
      substituteInPlace "$f" \
        --replace-fail '            ? Config.options.background.thumbnailPath' '            ? Images.videoFramePath(path)'
    done

    # ── Bar islands that follow the wallpaper (see barIslandQml).
    cp ${barIslandQml.service} $qs/services/WallpaperRegions.qml
    G=$qs/modules/ii/bar/BarGroup.qml
    substituteInPlace $G \
      --replace-fail 'import QtQuick.Layouts' 'import QtQuick.Layouts
import Quickshell
import qs.services' \
      --replace-fail '                            ? Appearance.colors.colLayer0' \
                     '                            ? (root.islandPainted ? "transparent" : Appearance.colors.colLayer0)'
    insert_after $G '    property color bgColor: Appearance.colors.colPrimaryContainer' ${barIslandQml.props} '    '
    insert_after $G '    default property alias items: gridLayout.children' ${barIslandQml.background} '    '
    [ "$(grep -c '^import Quickshell$' $G)" = "1" ] || exit 1
    [ "$(grep -c 'root.islandPainted' $G)" = "2" ] || exit 1

    # Segmented groups without their outline. Upstream draws a 1px border
    # round every segment and overlaps neighbours by the border's width
    # (-1, and -2 on the vertical bar) so adjacent borders coincide. With no
    # border the overlap would be a seam instead: two translucent islands
    # stacked on one line of pixels. So segments butt up against each other.
    substituteInPlace $G \
      --replace-fail 'border.width: root.paintBackground && root.isSegmented && !root.isMaterial ? 1 : 0' \
                     'border.width: 0'
    for f in $qs/modules/ii/bar/BarContent.qml $qs/modules/ii/verticalBar/VerticalBarContent.qml; do
      [ "$(grep -cE '^ +: Config.options\?.bar.borderless === "segmented" \? -[12]$' "$f")" = "3" ] || {
        echo "$f: expected three segmented overlaps" >&2
        exit 1
      }
      sed -i -E 's/^( +: Config.options\?.bar.borderless === "segmented" \? )-[12]$/\10/' "$f"
    done

    # switchwall.sh: the reordered video branch (see videoSwitch), the IPC
    # socket in the restore script that relaunches mpvpaper at login, scheme
    # detection reading the frame instead of the video, and is_video
    # case-insensitive.
    #
    # The 1080p30 copy (see videoProxy) is made in main(), before switch()
    # tears anything down, so the old wallpaper stays up for the length of a
    # conversion rather than going black — the selector shows the new video's
    # frame meanwhile. A conversion can take long enough to pick something
    # else in the middle of it, so every switch leaves its pid in a stamp and a
    # video switch that finds the stamp changed after converting exits instead
    # of overriding the newer pick. The restore script asks videoProxy by name,
    # once before its per-monitor loop, so a login after the cache was cleared
    # converts once rather than per monitor. A lock screen video is picked
    # through the colors-only lock mode, which only reads its frame; its copy
    # is started there in the background, so the first lock can play it.
    #
    # profile=fast: mpv's render pass went from 30% to 12% of the iGPU per
    # monitor with it, same video, nothing dropped either way. A 1080p video
    # on a 1080p screen is not scaled, so what it gives up is the dither.
    sed 's/^./            &/' ${videoSwitch.old} > $TMPDIR/switch-old
    sed 's/^./            &/' ${videoSwitch.new} > $TMPDIR/switch-new
    substituteInPlace $qs/scripts/colors/switchwall.sh \
      --replace-fail "$(cat $TMPDIR/switch-old)" "$(cat $TMPDIR/switch-new)" \
      --replace-fail 'video-align-y=0.5 load-scripts=no"' 'video-align-y=0.5 load-scripts=no profile=fast"' \
      --replace-fail 'mpvpaper -o "$VIDEO_OPTS" "\$monitor" "$video_path"' \
                     'mpvpaper -o "$VIDEO_OPTS input-ipc-server=\$XDG_RUNTIME_DIR/mpvpaper-\$monitor.sock" "\$monitor" "\$video"' \
      --replace-fail '    switch "$imgpath" "$mode_flag"' '    if [[ -z "$colors_only_flag" ]]; then
        echo $$ > "$XDG_RUNTIME_DIR/ii-switchwall.latest"
        if is_video "$imgpath"; then
            ${videoProxy}/bin/ii-video-proxy "$imgpath" >/dev/null
            [ "$(cat "$XDG_RUNTIME_DIR/ii-switchwall.latest" 2>/dev/null)" = "$$" ] || exit 0
        fi
    elif [[ -n "$colors_lock_flag" ]] && is_video "$imgpath"; then
        ${pkgs.util-linux}/bin/setsid -f ${videoProxy}/bin/ii-video-proxy "$imgpath" >/dev/null 2>&1 < /dev/null
    fi
    switch "$imgpath" "$mode_flag"' \
      --replace-fail 'detected_type="$(detect_scheme_type_from_image "$imgpath")"' \
                     'detected_type="$(detect_scheme_type_from_image "$(is_video "$imgpath" && ${videoFrame} "$imgpath" || echo "$imgpath")")"' \
      --replace-fail '    local extension="''${1##*.}"' '    local extension="''${1##*.}"; extension="''${extension,,}"'
    [ "$(grep -c 'input-ipc-server=' $qs/scripts/colors/switchwall.sh)" = "2" ] || exit 1
    # Inside create_restore_script's unquoted heredoc: \$( runs at login,
    # $video_path is the original, filled in when the script is written.
    printf '%s\n' 'video="\$(ii-video-proxy "$video_path" 2>/dev/null || echo "$video_path")"' > $TMPDIR/restore-video
    insert_after $qs/scripts/colors/switchwall.sh 'pkill -f -9 mpvpaper' $TMPDIR/restore-video ""
    [ "$(grep -c 'ii-video-proxy' $qs/scripts/colors/switchwall.sh)" = "4" ] || exit 1
    # The lock screen's own mpvpaper uses the same options (see videoOpts).
    grep -qxF 'VIDEO_OPTS="${videoOpts}"' $qs/scripts/colors/switchwall.sh || {
      echo "switchwall.sh: VIDEO_OPTS no longer matches videoOpts" >&2
      exit 1
    }

    # ── The restore script never ran on this machine.
    #
    # switchwall.sh writes it with a #!/bin/bash shebang, and NixOS has no
    # /bin/bash: execs.lua's exec failed with "bad interpreter" at every login,
    # silently, so a video wallpaper came back as an empty screen — the shell
    # goes transparent because the config says video, and nothing was playing
    # behind it. Both heredocs get /usr/bin/env, and execs.lua runs the script
    # through bash as well, because the script is in mutablePaths and one
    # written before this fix keeps its old shebang until the next video
    # wallpaper is applied.
    #
    # And the kill before each start was `pkill -f mpvpaper`, which matches the
    # word anywhere in any command line: the thumbnail pass's ffmpeg writing to
    # .../mpvpaper_thumbnails/, ii-mpvpaper-ctl, an editor with the file open.
    # Anchored on argv[0] it only matches mpvpaper itself. (Not -x: the
    # process is the wrapper's .mpvpaper-wrapp, which argv[0] still names.)
    substituteInPlace $qs/scripts/colors/switchwall.sh \
      --replace-fail '#!/bin/bash' '#!/usr/bin/env bash' \
      --replace-fail 'pkill -f -9 mpvpaper' "pkill -9 -f '^[^ ]*mpvpaper '"
    [ "$(grep -c '#!/bin/bash' $qs/scripts/colors/switchwall.sh || true)" = "0" ] || exit 1
    [ "$(grep -c "pkill -9 -f '^\[^ \]\*mpvpaper '" $qs/scripts/colors/switchwall.sh)" = "2" ] || exit 1
    substituteInPlace $out/.config/hypr/hyprland/execs.lua \
      --replace-fail 'hl.exec_cmd("$HOME/.config/hypr/custom/scripts/__restore_video_wallpaper.sh")' \
                     'hl.exec_cmd("bash $HOME/.config/hypr/custom/scripts/__restore_video_wallpaper.sh")'

    # ── Blur over a live wallpaper (see blurCache).
    #
    # The video branch turns the blur cache off (in videoSwitch); the image
    # branch, which is where upstream clears the restore script, turns it
    # back on. That remove_restore is the only one at this depth — the other
    # sits one level deeper, in the video branch's failure path.
    insert_after $qs/scripts/colors/switchwall.sh '                remove_restore' \
      ${pkgs.writeText "ii-video-switch-image" "${blurCache true}\n"} '                '
    [ "$(grep -c 'new_optimizations = ' $qs/scripts/colors/switchwall.sh)" = "2" ] || exit 1

    cat >> $out/.config/hypr/hyprland/rules.lua <<'IIRULES'

-- No blur where it can never be seen; it made a video wallpaper stutter (NixOS config, ii-session.nix)
hl.layer_rule({ match = { namespace = "quickshell:background" }, blur = false })
hl.layer_rule({ match = { namespace = "quickshell:screenframe" }, blur = false })
hl.layer_rule({ match = { namespace = "quickshell:screenCorners" }, blur = false })

-- Bar islands are 65% opaque over the wallpaper; blur them anyway, and blur what is really
-- behind them: xray reads the blur cache, which is off under a video wallpaper, and then blurs
-- black, so bright wallpaper gave near-black islands (NixOS config, ii-session.nix)
hl.layer_rule({ match = { namespace = "quickshell:bar" }, ignore_alpha = 0.3 })
hl.layer_rule({ match = { namespace = "quickshell:verticalBar" }, ignore_alpha = 0.3 })
hl.layer_rule({ match = { namespace = "quickshell:bar" }, xray = false })
hl.layer_rule({ match = { namespace = "quickshell:verticalBar" }, xray = false })
IIRULES

    cat >> $out/.config/hypr/hyprland/general.lua <<'IIGENERAL'

-- No blur cache while a video wallpaper is set: it goes stale every video frame (NixOS config, ii-session.nix)
local restore = io.open(HOME .. "/.config/hypr/custom/scripts/__restore_video_wallpaper.sh", "r")
if restore then
    local script = restore:read("*a") or ""
    restore:close()
    if script:find("mpvpaper -o", 1, true) then
        hl.config({ decoration = { blur = { new_optimizations = false } } })
    end
end
IIGENERAL

    # Settings > Animations presets write shellOverrides/animations.lua, but
    # upstream hyprland.lua never requires it, so picking a preset did nothing
    # (windows kept general.lua's animations). Loaded last so the preset wins;
    # guarded because the file only exists once a preset has been chosen.
    grep -q '^require("hyprland.shellOverrides.main")$' $out/.config/hypr/hyprland.lua
    cat >> $out/.config/hypr/hyprland.lua <<'IIANIM'
if is_file_exists(HOME .. "/.config/hypr/hyprland/shellOverrides/animations.lua") then
    require("hyprland.shellOverrides.animations")
end
IIANIM

    # ── The lock screen palette must not leak into the desktop.
    #
    # Setting a lock screen wallpaper runs switchwall.sh --colors_lock, which
    # is meant to produce colors-lock.json and nothing else. Two things leaked:
    #
    #   pre_process() still ran, so a dark lock wallpaper behind a light
    #   desktop wrote prefer-dark to dconf. Zen, VS Code and every GTK/Qt app
    #   follow that key live and turned dark while the shell stayed light,
    #   until they were restarted after the next real wallpaper change.
    #
    #   matugen writes every target in matugen/config.toml, but only
    #   colors.json and the two gtk.css were backed up and put back — so
    #   Hyprland's border colours, fuzzel, hyprlock and color.txt silently
    #   took the lock palette.
    #
    # The mode is still derived from the lock image; it only steers that
    # palette now, not the session.
    substituteInPlace $qs/scripts/colors/switchwall.sh \
      --replace-fail '    pre_process "$mode_flag"' \
                     '    [[ -n "$colors_lock_flag" ]] || pre_process "$mode_flag"' \
      --replace-fail '        "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"' \
                     '        "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
        "$XDG_CONFIG_HOME/hypr/hyprland/colors.lua"
        "$XDG_CONFIG_HOME/hypr/hyprlock/colors.conf"
        "$XDG_CONFIG_HOME/fuzzel/fuzzel_theme.ini"
        "$STATE_DIR/user/generated/color.txt"
        "$STATE_DIR/user/generated/wallpaper/path.txt"'
    # Guard against matugen gaining a target this list does not restore.
    [ "$(grep -c "^output_path" $out/.config/matugen/config.toml)" = "8" ] || {
      echo "matugen/config.toml: target count changed, update the colors_lock restore list" >&2
      exit 1
    }

    # ── Clipboard: picking an entry pastes it.
    #
    # Two upstream problems. Cliphist.paste() exists but its classic-cliphist
    # branch ends in `wl-copy && wl-paste`, and wl-paste only prints the
    # clipboard to stdout — it does not press anything; the Stash branch right
    # below it correctly runs pressPasteCommand. And the launcher's clipboard
    # entries call copy(), never paste(), so selecting one left you to hit
    # Ctrl+V yourself.
    #
    # pressPasteCommand is `ydotool key -d 1 29:1 47:1 47:0 29:0` — Ctrl down,
    # V down, V up, Ctrl up. Being a keystroke rather than a data transfer, it
    # is format-agnostic: images and anything else the clipboard holds paste
    # the same way. ydotoold is already running (programs.ydotool.enable in
    # ../modules/hyprland-desktop.nix) and the user is in the ydotool group.
    #
    # Only the entry's primary action changes. The explicit "Copy" action next
    # to it stays copy-only, which is the whole point of having it.
    for f in $out/.config/quickshell/*/services/Cliphist.qml; do
      [ -e "$f" ] || continue
      substituteInPlace "$f" --replace-fail \
        'decode | wl-copy && wl-paste`]);' \
        'decode | wl-copy && sleep ''${root.pasteDelay} && ''${root.pressPasteCommand}`]);'
    done

    # Only the entry's primary action — the first of the two Cliphist.copy
    # calls in the file. The second is the explicit "Copy" action listed beside
    # it, which must stay copy-only; that is the whole point of having it.
    #
    # `0,/re/s//x/` replaces the first match and nothing else. A multi-line
    # --replace-fail anchor was the obvious alternative and does not work here:
    # Nix strips the common indentation from a multi-line string, so the
    # anchor's continuation lines arrive four spaces short of the file's.
    for f in $out/.config/quickshell/*/services/LauncherSearch.qml; do
      [ -e "$f" ] || continue
      before=$(grep -c 'Cliphist\.copy(entry);' "$f")
      [ "$before" = "2" ] || { echo "LauncherSearch.qml: expected 2 Cliphist.copy call sites, found $before" >&2; exit 1; }
      sed -i '0,/Cliphist\.copy(entry);/s//Cliphist.paste(entry);/' "$f"
      grep -q 'Cliphist\.paste(entry);' "$f"
      [ "$(grep -c 'Cliphist\.copy(entry);' "$f")" = "1" ] || exit 1
    done

    # ── Shell restart (see shellRestart above).
    substituteInPlace $out/.config/hypr/hyprland/keybinds.lua \
      --replace-fail \
        'hl.dsp.exec_cmd("killall ydotool qs quickshell; qs -c $qsConfig &")' \
        'hl.dsp.exec_cmd("${shellRestart}")'

    # ── The four app keys.
    #
    # Three of them (SUPER+SHIFT+Z, +V, +O) were chosen to match the caelestia
    # session key for key, back when both sessions existed and an editor that
    # opened on one and did nothing on the other was the worst outcome. That
    # session is gone; the keys stay because they are the ones in muscle
    # memory, which is the same reason the capture keys above were aligned.
    #
    # The fourth deliberately did NOT match: caelestia put pwvucontrol on
    # SUPER+B, and here it is SUPER+SHIFT+B, because SUPER+B is upstream's
    # second key for the left sidebar — a panel caelestia had no equivalent
    # of. Asked for explicitly, and the asymmetry was the point rather than an
    # oversight.
    #
    # SUPER+SHIFT+B was not free either — it is upstream's "Media: Previous
    # track" (keybinds.lua:135-136). That is the one thing this change costs,
    # and it costs little: previous-track keeps XF86AudioPrev (:132, the media
    # key on the external keyboard, which presents a Consumer Control device)
    # and SUPER+SHIFT+ALT+mouse:275 (:133). Next/play-pause are
    # untouched.
    #
    # A replacement rather than an added bind, in both directions: Hyprland
    # fires every bind that matches, so an extra SUPER+SHIFT+B would skip a
    # track every time the volume window opened.
    #
    # volume-control-toggle is defined in the let block above — it came over
    # from the caelestia session, which was its original home and is now this
    # bind's only caller. It exists because pwvucontrol is GTK4 with no
    # single-instance handling: a plain exec stacks a new window on every
    # press.
    #
    # sed with N rather than --replace-fail, because this bind spans two lines
    # and Nix strips the common indentation from a multi-line string, so the
    # anchor's continuation line would arrive four spaces short of the file's
    # — the same trap documented at the LauncherSearch patch above. N pulls
    # the options line into the pattern space and both become one line.
    # Counted before and after: the anchor is unique, and so is the
    # description it carries.
    before=$(grep -c 'hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd("playerctl previous"),' \
      $out/.config/hypr/hyprland/keybinds.lua)
    [ "$before" = "1" ] || { echo "SUPER+SHIFT+B: expected 1 anchor, found $before" >&2; exit 1; }
    sed -i '/^hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd("playerctl previous"),$/{N;s|.*|hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd("volume-control-toggle"), { description = "App: Volume control" })|}' \
      $out/.config/hypr/hyprland/keybinds.lua
    grep -q 'hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd("volume-control-toggle")' \
      $out/.config/hypr/hyprland/keybinds.lua
    [ "$(grep -c 'Media: Previous track' $out/.config/hypr/hyprland/keybinds.lua)" = "0" ] || exit 1
    # The left sidebar keeps all three of upstream's keys (SUPER+A, +B, +O);
    # nothing here touches them.
    [ "$(grep -c 'quickshell:sidebarLeftToggle"' $out/.config/hypr/hyprland/keybinds.lua)" = "3" ] || exit 1

    # Appended rather than substituted: these three replace nothing, and
    # keybinds.lua is a flat list of top-level statements, so the end of the
    # file is as good a place as any and reads as ours rather than upstream's.
    #
    # `code`, not `uwsm app -- code` as session A spells it. Session B is
    # deliberately not uwsm (../modules/ii-session.nix says why), so there is
    # no uwsm session for `uwsm app` to attach to. The cost is real and worth
    # naming: ../home/app-limits.nix caps VS Code through the
    # app-Hyprland-code-<hex>.scope that `uwsm app` creates, so VS Code runs
    # uncapped in this session. Zen is unaffected — flatpak makes its own
    # transient scope, which is what that file's drop-in actually targets.
    cat >> $out/.config/hypr/hyprland/keybinds.lua <<'IIBINDS'

--# Apps, aligned with the caelestia session
hl.bind("SUPER + SHIFT + Z", hl.dsp.exec_cmd("flatpak run app.zen_browser.zen"), { description = "App: Zen browser" })
hl.bind("SUPER + SHIFT + V", hl.dsp.exec_cmd("code"), { description = "App: VS Code" })
hl.bind("SUPER + SHIFT + O", hl.dsp.exec_cmd("obsidian"), { description = "App: Obsidian" })

--# Close every window one by one while held; letting go of any key stops it
local closeSeqToken = nil
local function closeSeqStop()
    if closeSeqToken then
        hl.dispatch(hl.dsp.exec_cmd("${closeSequential} stop " .. closeSeqToken))
        closeSeqToken = nil
    end
end
hl.bind("SUPER + SHIFT + Q", function()
    closeSeqStop()
    closeSeqToken = os.time() .. "-" .. math.random(1, 1000000000)
    hl.dispatch(hl.dsp.exec_cmd("${closeSequential} start " .. closeSeqToken))
end, { description = "Window: Close all, one by one (hold)" })
hl.bind("SUPER + SHIFT + Q", closeSeqStop, { release = true })
--# Not bare Q or SHIFT_*: a release bind on a plain key swallows its press
--# even with transparent, so q stopped typing. SUPER_* already carry the same
--# kind of bind upstream (workspaceNumber, top of this file) without harm.
for _, key in ipairs({ "SUPER_L", "SUPER_R" }) do
    hl.bind(key, closeSeqStop, { release = true, ignore_mods = true, transparent = true })
end
IIBINDS

    # ── Bluetooth pairing agent.
    #
    # ../modules/bluetooth.nix enables blueman, but its applet is a D-Bus/
    # systemd user unit nothing in this session starts, and kded6 — whose
    # bluedevil module is the other agent — is killed by ConflictKiller.qml.
    # With no agent, pairing a device that asks for a PIN or confirmation fails
    # silently. Started from here so it inherits the session's WAYLAND_DISPLAY.
    sed -i '/^    hl.exec_cmd("easyeffects --hide-window --service-mode")$/a\    hl.exec_cmd("blueman-applet")' \
      $out/.config/hypr/hyprland/execs.lua
    grep -q '^    hl.exec_cmd("blueman-applet")$' $out/.config/hypr/hyprland/execs.lua

    # ── Gemini 3.6 Flash and DeepSeek V4 Flash at the top of the sidebar's
    # model list; Gemini is also the default for a fresh states.json. See
    # aiModelEntries in the let block.
    # Nix strips the entries' indentation when it builds the file; put Ai.qml's
    # back.
    sed 's/^./        &/' ${aiModelEntries} > $TMPDIR/ai-model-entries
    for s in ii ${qsConfig}; do
      sed -i '/^    property var models: Config.options.policies.ai === 2 ? {} : {$/r '"$TMPDIR"'/ai-model-entries' \
        $out/.config/quickshell/$s/services/Ai.qml
      grep -q '"model": "${geminiModel}",' $out/.config/quickshell/$s/services/Ai.qml
      grep -q '"model": "${gonkaModel}",' $out/.config/quickshell/$s/services/Ai.qml
      substituteInPlace $out/.config/quickshell/$s/modules/common/Persistent.qml \
        --replace-fail 'property string model: "gemini-2.5-flash"' 'property string model: "${geminiModel}"'

      # A stalled stream must end. Upstream's curl has no timeout at all, and
      # Gemini under load sometimes stops sending mid-answer while keeping the
      # connection open: seen here as a request.sh curl still ESTABLISHED four
      # minutes in with nothing arriving, the message never marked done, the
      # reply frozen mid-sentence. 90s of silence rather than a total cap, so a
      # long answer is never cut, and generous because a thinking model can be
      # quiet for a while before its first chunk. Exit 28 is curl's timeout;
      # it gets a visible note instead of just ending mid-sentence.
      substituteInPlace $out/.config/quickshell/$s/services/Ai.qml \
        --replace-fail 'scriptRequestContent += `curl --no-buffer "''${endpoint}"`' \
                       'scriptRequestContent += `curl --no-buffer --connect-timeout 15 --speed-limit 1 --speed-time 90 "''${endpoint}"`' \
        --replace-fail 'const result = requester.currentStrategy.onRequestFinished(requester.message);' \
                       'const result = requester.currentStrategy.onRequestFinished(requester.message);
            if (exitCode === 28) {
                const stallNote = "\n\n*(Stream stalled, no data for 90s. Press regenerate to retry.)*";
                requester.message.rawContent += stallNote;
                requester.message.content += stallNote;
            }'
    done

    # The About page restarts the shell the same broken way.
    for f in $out/.config/quickshell/*/modules/ii/settings/pages/About.qml; do
      [ -e "$f" ] || continue
      sed -i 's|killall qs 2>/dev/null \|\| true|qs kill 2>/dev/null \|\| pkill -f '"'"'quickshell -c'"'"' 2>/dev/null \|\| true|' "$f"
    done

    # ── The config root rewrite. Must be last: it rewrites the line added above
    # along with everything else.
    #
    # Every "/.config/" in these trees means "the shell's config root". The
    # already-XDG-aware sites read ''${XDG_CONFIG_HOME:-$HOME/.config} with no
    # trailing slash and so are not matched — they resolve correctly on their
    # own once the session sets XDG_CONFIG_HOME.
    #
    # A literal substitution rather than rewriting each site to read
    # $XDG_CONFIG_HOME: the same string appears in shell ($HOME/.config/...),
    # in Lua (HOME .. "/.config/..."), in Python argparse defaults that go
    # through expanduser (~/.config/...) and in TOML (matugen's output_path).
    # Only a literal preserves every one of those expansion mechanisms.
    # `|| true` on every grep here: grep exits 1 when it matches nothing, and
    # matching nothing is the success condition for the `after` count. stdenv
    # runs the builder under `set -e -o pipefail`, so an unguarded pipeline
    # would abort the build at the moment the rewrite succeeded — silently,
    # since grep prints nothing on no-match.
    before=$({ grep -rIo '/\.config/' $out || true; } | wc -l)
    { grep -rIlZ '/\.config/' $out || true; } | xargs -0 -r sed -i 's|/\.config/|/${cfgDirName}/|g'
    after=$({ grep -rIo '/\.config/' $out || true; } | wc -l)
    echo "config-root rewrite: $before -> $after"
    if [ "$before" -lt 40 ] || [ "$after" -ne 0 ]; then
      echo "unexpected rewrite count — upstream changed how it spells its config root" >&2
      exit 1
    fi
  '';

  # ── Files these dots write to at runtime.
  #
  # home-manager's recursive source makes real directories but symlinks every
  # file into the store, and writing through such a symlink is EACCES. These
  # are the paths something actually writes, so they are pulled out of the
  # linked tree and seeded as real copies instead (the activation below).
  #
  # Seeded once, then yours: a rebuild will not overwrite one that exists. That
  # is upstream's own model for the custom/ folder, and without it the Settings
  # panel would be decorative — every nixos-rebuild would revert it. The price
  # is that these eleven paths are not reproducible from the flake; delete one
  # to have it seeded again.
  #
  #   hypr/custom/                  6 files created at startup by
  #                                 hyprland/services/create_custom_config.lua
  #   hypr/hypridle.conf            hypridleconfigurator.py
  #   hypr/hyprland/shellOverrides/ hyprconfigurator.py
  #   hypr/monitors.lua             monitor_configurator.py (not shipped)
  #   matugen/config.toml           end4-pC services/SystemTheming.qml, which
  #                                 backs it up once as config.toml.orig and
  #                                 regenerates it whenever a matugen template
  #                                 is toggled in Settings
  #   the five matugen outputs      rewritten on every wallpaper change
  # Second group: application configs that the applications themselves rewrite.
  # These are not shell state — they are ordinary app config files that happen
  # to be shipped by these dots, and every one of them belongs to a program
  # that saves over it. fish/fish_variables is the one that proved the rule: it
  # is fish's universal-variable store, written on every `set -U`, so a
  # symlinked one turns every new shell in the session into a wall of
  # "Read-only file system (os error 30)".
  #
  # kdeglobals matters most of the two dozen: KDE apps rewrite it on any
  # appearance change, and the colour pipeline writes it too — matugen's
  # templates/kde/kde-material-you-colors-wrapper.sh regenerates it from the
  # wallpaper. Read-only, the whole Qt side of the theming silently stops.
  #
  # If some other app here turns out to save over its config, the fix is one
  # more line in this list.
  mutablePaths = [
    "fish/fish_variables"
    "kdeglobals"
    "dolphinrc"
    "konsolerc"
    "darklyrc"
    "Kvantum/kvantum.kvconfig"
    "kde-material-you-colors/config.conf"

    "hypr/custom"
    "hypr/hypridle.conf"
    "hypr/hyprlock.conf"
    "hypr/hyprland/shellOverrides"
    "hypr/hyprland/colors.lua"
    "hypr/hyprlock/colors.conf"
    "hypr/monitors.lua"
    "matugen/config.toml"
    "fuzzel/fuzzel_theme.ini"
    "gtk-3.0/gtk.css"
    "gtk-4.0/gtk.css"
  ];

  # Paths kept as one definition, shared with ~/.config rather than shipped
  # by the dots. The comment on home.file says why these four and nothing
  # else.
  sharedFromConfigHome = [ "git" "menus" "mimeapps.list" "dconf" ];

  # The tree minus the mutable paths — this is what gets symlinked.
  linked = pkgs.runCommand "illogical-impulse-linked" { } ''
    cp -r ${dots}/.config $out
    chmod -R u+w $out
    ${lib.concatMapStringsSep "\n" (p: "rm -rf $out/${p}") mutablePaths}
  '';

  # Just the mutable paths, for the seeding activation. Some of them are
  # generated at runtime and shipped by nobody; those simply aren't here.
  seed = pkgs.runCommand "illogical-impulse-seed" { } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (p: ''
      if [ -e ${dots}/.config/${p} ]; then
        mkdir -p "$(dirname $out/${p})"
        cp -r ${dots}/.config/${p} $out/${p}
      fi
    '') mutablePaths}
  '';
in {
  # ── The tree itself.
  #
  # recursive = true: a plain directory source symlinks the whole tree
  # read-only, and then nothing can create hypr/custom/*.lua or
  # illogical-impulse/config.json at runtime. recursive makes real directories
  # and symlinks the files individually.

  # ── Tooling this session has to share with the rest of the user.
  #
  # The session reads ~/.config-ii, so everything home-manager writes into
  # ~/.config is invisible to it. For the dots that is the point — ii ships
  # its own fish, kitty, foot, fontconfig, gtk-3.0 and starship.toml, and
  # would rather not see home-manager's. But four of those paths are not
  # look-and-feel, and losing them breaks work rather than changing
  # appearance:
  #
  #   git            without ~/.config/git/config the only thing left is a
  #                  stale unmanaged ~/.gitconfig whose key is misspelled
  #                  `user.mail`, so git sees no address and refuses to commit
  #                  at all ("Author identity unknown"). It also drops
  #                  ../home/git.nix's url."git@github.com:".insteadOf, which
  #                  is the only reason pushes to an https remote go over SSH.
  #   mimeapps.list  default application for every file type
  #   menus          menus/applications.menu, from ../home/mime.nix
  #   dconf          light/dark mode and the GTK theme, for BOTH sessions
  #
  # dconf is the one that actually broke something visible. Session B started
  # with no ~/.config-ii/dconf/user at all, so `gsettings get
  # org.gnome.desktop.interface color-scheme` answered 'default', the portal
  # reported color-scheme = 0 ("no preference") to every client, and all GTK
  # and Qt apps rendered light while the shell stayed on its last matugen
  # palette. The shell reads the same key as its source of truth
  # (scripts/colors/switchwall.sh, the `if [[ -z "$mode_flag" ]]` branch), so
  # it computed "light" too and the two disagreed about what it had computed.
  #
  # Sharing it also fixes a worse, non-deterministic half: dconf reads and
  # writes both go through a D-Bus-activated service, and ii's execs.lua runs
  # `dbus-update-activation-environment --all`, so which database that service
  # ends up bound to depends on whether it was activated before or after that
  # line ran. With one database the race stops mattering.
  #
  # The deliberate consequence: light/dark and the GTK theme are now one
  # setting for the whole user. Changing the wallpaper in ii retints session A
  # as well — ../home/qt.nix and ../home/themes.nix watch these very keys and
  # will follow. That is what was asked for, and it is the honest model
  # anyway: light/dark is a property of the person, not of the dotfiles.
  #
  # mkOutOfStoreSymlink rather than copying the same source into both trees:
  # this points at the live ~/.config path, so whatever home-manager generates
  # for session A is what session B reads, with no second definition that can
  # drift. Nothing writes to any of the three — in session A they are already
  # read-only store symlinks — so the indirection costs nothing.

  home.file =
    {
      ${cfgDirName} = {
        source = linked;
        recursive = true;
      };
    }
    # The four shared paths, linked at their live ~/.config location.
    // lib.listToAttrs (map (name:
      lib.nameValuePair "${cfgDirName}/${name}" {
        source = config.lib.file.mkOutOfStoreSymlink
          "${config.home.homeDirectory}/.config/${name}";
      }) sharedFromConfigHome);

  # ── VS Code follows the session's light/dark inside this config root too.
  #
  # ../home/vscode.nix already solves this for session A: vscode-theme-settings
  # writes the theme matching dconf's color-scheme into Code/User/settings.json
  # (and its vscode-theme-sync watcher redoes it live, for this root too),
  # editing the JSONC in place rather than
  # replacing it, because VS Code rewrites that file itself and a store symlink
  # would make it drop every setting written that way.
  #
  # It reads its target from XDG_CONFIG_HOME at run time, so the same binary
  # serves both roots — hence the extraction into
  # ../home/vscode-theme-settings.nix. Without this, VS Code in session B keeps
  # whatever theme it was last on while everything else on screen follows the
  # wallpaper.
  home.activation.iiVscodeTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    XDG_CONFIG_HOME="${cfgDir}" run ${
      import ../vscode-theme-settings.nix { inherit pkgs; }
    }/bin/vscode-theme-settings
  '';

  # ── Seed-once copies of everything written at runtime.
  home.activation.iiSessionMutableConfigs =
    lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatMapStringsSep "\n" (p: ''
        if [ -e ${seed}/${p} ] && [ ! -e "${cfgDir}/${p}" ]; then
          run mkdir -p "$(dirname "${cfgDir}/${p}")"
          run cp -r ${seed}/${p} "${cfgDir}/${p}"
          run chmod -R u+w "${cfgDir}/${p}"
        fi
      '') mutablePaths
    );

  # ── What runs ii-zen-accent.
  #
  # A .path unit rather than a patch to switchwall.sh's post_process(), where
  # the VS Code colour hook lives. Two reasons: the palette is rewritten from
  # more places than a wallpaper change (a bare regenerate, --noswitch, the
  # shell re-applying after a restart), and watching the output file catches
  # all of them without having to find each caller; and it keeps one more
  # substituteInPlace out of the `dots` derivation, where every anchor is a
  # thing upstream can rename.
  #
  # PathChanged, not PathModified: matugen writes the file and closes it, and
  # PathChanged fires on that close rather than on each intermediate write —
  # so the script never reads a half-written colours.json.
  #
  # default.target, not graphical-session.target, for the reason ../home/
  # qt.nix's watcher spells out: the plain "Hyprland" fallback session in the
  # greeter never reaches graphical-session.target.
  systemd.user.paths.ii-zen-accent = {
    Unit.Description = "Watch this session's matugen palette for Zen's accent";
    Path = {
      PathChanged = zenAccentColors;
      Unit = "ii-zen-accent.service";
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.ii-zen-accent = {
    Unit.Description = "Write the wallpaper's accent into Zen's profile";
    Service = {
      Type = "oneshot";
      # Named explicitly because systemd --user is session A's environment,
      # and because the script's own default is only right by coincidence —
      # it happens to be the same path today, and saying so here is what
      # keeps this unit pointed at session B if that default ever moves.
      Environment = [ "ZEN_ACCENT_COLORS=${zenAccentColors}" ];
      ExecStart = "${zenAccent}/bin/ii-zen-accent apply";
    };
  };

  # ── Packages.
  #
  # Derived from upstream's own nixpkgs mapping, sdata/dist-nix/home-manager/
  # home.nix, with the non-NixOS half dropped (nixGL, targets.genericLinux and
  # the PAM/GPU workarounds it needs, none of which apply here).
  #
  # This is one profile shared with session A — there is no per-session
  # home.packages — so anything already installed by ../home/packages.nix or
  # ../modules/package.nix is deliberately not repeated here.
  #
  # One thing is still missing and packaged nowhere: breeze-plus, a Breeze
  # fork that kde-material-you-colors offers as an option and falls back to
  # plain breeze without. microtex used to be on this list too and is built
  # above now; qt6-avif-image-plugin turned out to be kimageformats under
  # another name and is on QT_PLUGIN_PATH in ../modules/ii-session.nix.
  home.packages = with pkgs; [
    # The shell runtime itself. Inherited from the dropped caelestia session,
    # which is the only reason it was ever somewhere else — see the let block.
    quickshell # `qs`
    venv
    # No microtex here: nothing runs it from PATH. The QML is pointed at its
    # store path in `dots` above, and that reference is what keeps it alive —
    # putting it in the profile would only add an ~/.nix-profile/opt/MicroTeX
    # nobody looks at.
    autoLightDarkCtl # `ii-lightdark-auto [status|on|off|toggle]`
    zenAccent # `ii-zen-accent [apply|--restart|auto ...]`, see the unit below
    plasmaTools # plasma-apply-colorscheme + plasma-changeicons, see above

    # No fonts here on purpose — they are system-wide in
    # ../modules/ii-session.nix, which installs google-fonts, material-symbols
    # and rubik. home-manager advertises profile fonts through
    # ~/.config/fontconfig/conf.d/10-hm-fonts.conf, which lives in the config
    # root session B does not read, so a font in this list would be invisible
    # in the one session that wants it.

    # ── Everything below came over from ../home/caelestia.nix when the
    # caelestia session was dropped. It is here rather than in
    # ./packages.nix because each one is reached by name from inside these
    # dots, so losing it breaks a bind or a panel rather than a convenience.
    fuzzel # SUPER+V clipboard, SUPER+. emoji picker; its theme file is
           # generated by matugen (see mutablePaths)
    volumeControlToggle # SUPER+SHIFT+B, see the let block
    displayPower # `ii-display-power`, called by name from hypridle.conf
    pwvucontrol # what that toggle actually launches
    libnotify # notify-send, used from the shells and several scripts
    cliphist # the clipboard history both Cliphist.qml patches above drive;
             # execs.lua starts the two watchers, so no systemd unit here
    wl-clipboard # wl-copy / wl-paste, the other half of every clipboard path
    gnome-keyring # scripts/keyring/unlock.sh; the PAM and D-Bus halves are
                  # system-wide in ../modules/ii-session.nix
    libsecret # secret-tool: KeyringStorage.qml stores and looks up the AI
              # sidebar's API keys with it (and scripts/keyring/try_lookup.sh).
              # Without it `/key` saved nothing and every key read came back
              # empty, with no error shown.

    # Colour pipeline.
    matugen
    imagemagick
    libqalculate

    # The wallpaper picker. switchwall.sh with no path argument opens
    # `kdialog --getopenfilename` (scripts/colors/switchwall.sh:415), and so
    # do the sidebar's "choose image" and Settings' profile-preset import
    # (SidebarRightContent.qml:102, settings/pages/Profile.qml:541). Without
    # it every one of those is a no-op that leaves the old wallpaper up.
    kdePackages.kdialog

    # Video wallpapers. switchwall.sh detects a video by extension and then
    # needs both: mpvpaper to play it as the background layer, ffmpeg to pull
    # frame one out as the still that matugen reads the palette from
    # (switchwall.sh:202-239). It also writes hypr/custom/scripts/
    # __restore_video_wallpaper.sh, which execs.lua runs on every start — so
    # missing these is not one dead feature but a dead line in the autostart.
    mpvpaper
    ffmpeg
    videoProxy # `ii-video-proxy <video>`: the restore script calls it by name
               # at every login; also usable by hand, prints the file to play

    # "Open Upscayl" on the wallpaper notification (switchwall.sh:82). With it
    # absent the action falls through to a prompt offering `yay -S`, which on
    # this machine is advice for a different operating system.
    upscayl

    # Widgets and helpers the shell shells out to.
    wlogout
    hypridle
    hyprsunset
    songrec
    translate-shell
    wtype
    upower
    ddcutil
    brightnessctl
    playerctl

    # cava, NOT libcava. Upstream's own nixpkgs mapping says `libcava #cava`
    # and that mapping is wrong: libcava is the rendering library and ships
    # include/ and lib/ with no bin/ at all, while MediaControls.qml runs
    # `["cava", "-p", <raw_output_config>]` (MediaControls.qml:64) and wants
    # the executable. The visualizer next to the media controls stayed flat
    # for exactly this reason.
    cava
    lxqt.pavucontrol-qt

    # execs.lua starts `easyeffects --hide-window --service-mode` on every
    # session, and both shells carry a quick toggle plus an equalizer page
    # driving it (services/EasyEffects.qml, scripts/eq/equalizer.sh).
    easyeffects

    # pactl, for the two places that need to name a PulseAudio source: screen
    # recording WITH sound picks the monitor source (scripts/videos/
    # record.sh:23) and SongRec listens on it (scripts/musicRecognition/
    # recognize-music.sh:22-32). PipeWire answers the protocol here — what is
    # missing is only the client binary, which lives in this package and
    # nowhere else. Installing it starts no daemon: ../modules/audio.nix sets
    # services.pulseaudio.enable = false and that is untouched.
    pulseaudio

    # Screen capture.
    hyprshot
    slurp
    swappy
    wf-recorder
    tesseract

    # Basic tools the scripts assume.
    #
    # grim and jq are not optional: the Print bind is
    # `grim -o "$(hyprctl activeworkspace -j | jq -r '.monitor')" - | wl-copy`
    # (keybinds.lua:95-96) and the OCR fallback shells out to grim too, so
    # without them the screenshot keys fail silently. gojq below is a
    # different binary name and does not satisfy `jq`.
    grim
    jq
    bc
    gojq
    yq-go
    rsync
    eza

    # killall. The shellRestart script above carries psmisc on its own private
    # PATH, but four call sites reach for it from the session's PATH
    # instead: ConflictKiller.qml:36,40 (`killall kded6`, `killall mako
    # dunst`), killDialog.qml:92,103 and scripts/keyring/unlock.sh:18.
    psmisc

    # `file -b --mime-type`, used to decide how to show an attachment in the
    # AI chat and what icon a directory entry gets (AttachedFileIndicator.qml
    # :34, DirectoryIcon.qml:33).
    file

    # Qt/GTK theming the dots ship configs for.
    adw-gtk3
    kdePackages.breeze
    kdePackages.breeze-icons
    kdePackages.plasma-nm
    kdePackages.bluedevil

    # kcmshell6, which is how the panel opens the two KCMs above and the user
    # one: Config.qml:153-157 spells them `kcmshell6 kcm_bluetooth`,
    # `kcmshell6 kcm_networkmanagement`, `kcmshell6 kcm_users`. plasma-nm and
    # bluedevil only supply the modules — this supplies the thing that runs
    # them, and without it those buttons did nothing at all.
    #
    # kcmutils, not kde-cli-tools: the name suggests otherwise and every Arch
    # guide says otherwise, but in this nixpkgs kde-cli-tools' bin/ holds
    # kioclient, kstart, kde-open and friends with no kcmshell6 among them.
    # Checked by listing both.
    #
    # kcmutils and systemsettings, wrapped so the two KCMs above can load —
    # see kcmHosts in the let block.
    kcmHosts
  ];
}
