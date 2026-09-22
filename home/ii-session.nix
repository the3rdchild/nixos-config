{
  config,
  inputs,
  pkgs,
  lib,
  ...
}: let
  # ── Session B: illogical-impulse + the end4-pC fork.
  #
  # The whole point of this file is that it never touches session A. Session A
  # (caelestia, ../home/caelestia.nix) owns ~/.config; this one owns a second
  # config root and session B is launched with XDG_CONFIG_HOME pointed at it:
  #
  #   ~/.config/      caelestia          (untouched by anything here)
  #   ~/.config-ii/   illogical-impulse  (everything below)
  #
  # That split is cheap because the shell half of these dots is already
  # XDG-aware — 33 sites across ii and end4-pC read
  # ${XDG_CONFIG_HOME:-$HOME/.config} rather than hardcoding. Everything else
  # that matters (fish, kitty, foot, fontconfig, kdeglobals, Kvantum, matugen,
  # fuzzel, wlogout, mpv, dconf) honours XDG_CONFIG_HOME on its own, so the two
  # sessions simply never see each other's files.
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

  # ── The Python "venv".
  #
  # Upstream expects ILLOGICAL_IMPULSE_VIRTUAL_ENV to point at a real uv-built
  # venv in ~/.local/state and activates it in nine places — six shell
  # wrappers plus three scripts whose shebang is
  #   #!/usr/bin/env -S _/bin/sh_-c_"source_$(eval echo $I_I_VIRTUAL_ENV)/bin/activate&&exec_python_-E_..."
  # Rather than patch nine call sites, this builds the interpreter with Nix and
  # fakes the one file they all reach for: bin/activate. Sourcing it puts the
  # store env on PATH, which is all those call sites actually want.
  #
  # `python -E` in that shebang is the reason this needs checking rather than
  # assuming: -E makes CPython ignore PYTHONPATH. nixpkgs' python doesn't use
  # PYTHONPATH — withPackages resolves imports through the env's own prefix —
  # so -E is harmless here. Verified before this file was written.
  #
  # The list is upstream's sdata/uv/requirements.in minus the build-time-only
  # entries (build, wheel, setuptools-scm), which nothing imports at runtime.
  pythonEnv = pkgs.python3.withPackages (ps:
    with ps; [
      # Actually imported by scripts in both trees.
      materialyoucolor # 32 imports — the colour engine
      numpy
      opencv4 # cv2, used by find_regions / least-busy-region
      pygobject3 # gi
      pillow # PIL
      tqdm
      loguru
      click
      # Invoked as a command by matugen/templates/kde/*-wrapper.sh.
      kde-material-you-colors
      # Used by services/gCloud/token-from-key-venv.sh.
      google-auth
      requests
      # Upstream ships these; cheap, and kept so a script that grows a new
      # import doesn't fail at runtime in a session with no terminal attached.
      psutil
      pycairo
      libsass
      material-color-utilities
      setproctitle
      pywayland
    ]);

  venv = pkgs.runCommand "illogical-impulse-venv" { } ''
    mkdir -p $out/bin
    ln -s ${pythonEnv}/bin/* $out/bin/

    # Sourced, never executed — so no shebang, and it must be valid in both
    # bash and sh. Mirrors what a real venv's activate does, minus the prompt
    # mangling and the pyvenv.cfg lookup.
    cat > $out/bin/activate <<'ACTIVATE'
VIRTUAL_ENV="@venv@"
export VIRTUAL_ENV
_OLD_VIRTUAL_PATH="$PATH"
PATH="@python@/bin:$PATH"
export PATH
deactivate() {
    if [ -n "''${_OLD_VIRTUAL_PATH:-}" ]; then
        PATH="$_OLD_VIRTUAL_PATH"
        export PATH
        unset _OLD_VIRTUAL_PATH
    fi
    unset VIRTUAL_ENV
    unset -f deactivate
}
ACTIVATE
    substituteInPlace $out/bin/activate \
      --replace-fail '@venv@' "$out" \
      --replace-fail '@python@' '${pythonEnv}'
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

  # ── plasma-apply-colorscheme, without plasma-workspace.
  #
  # The Qt half of the colour pipeline calls this binary and it exists only in
  # kdePackages.plasma-workspace — 4307 MB of closure for one command, in a
  # config that deliberately dropped plasma6. ./ii-plasma-apply-colorscheme.py
  # explains what it does and, more importantly, what it deliberately does not.
  plasmaApplyColorscheme = pkgs.runCommand "plasma-apply-colorscheme" { } ''
    mkdir -p $out/bin
    substitute ${./ii-plasma-apply-colorscheme.py} \
      $out/bin/plasma-apply-colorscheme \
      --replace-fail '@python@' '${pkgs.python3}/bin/python3' \
      --replace-fail '@dbusSend@' '${pkgs.dbus}/bin/dbus-send'
    chmod +x $out/bin/plasma-apply-colorscheme
    patchShebangs --host $out/bin/plasma-apply-colorscheme
  '';

  # ── MicroTeX, the LaTeX renderer.
  #
  # Both shells render $$...$$ in an AI reply by shelling out to
  # `cd <microtexBinaryDir> && ./LaTeX -headless -input=... -output=<x>.svg`
  # (services/LatexRenderer.qml:24,60). The `cd` is not incidental: the binary
  # resolves its font metrics through tex::RES_BASE, which is the literal
  # relative string "res" (src/latex.cpp:14) and which the sample's CLI does
  # not expose — so the binary and its res/ tree have to sit in one directory
  # and that directory has to be the working directory. Hence the /opt-shaped
  # layout below: it is the one thing the QML already knows how to use, and
  # the patch in `dots` only has to move the path, not the mechanism.
  #
  # The build is upstream's own PKGBUILD minus its two seds. Its
  # tinyxml2.so.10 -> .11 rewrite is against a hardcoded soname this rev no
  # longer has, and its gtksourceviewmm-3.0 -> 4.0 rewrite exists because Arch
  # dropped the gtkmm3-era bindings; nixpkgs still ships them, so applying it
  # would be the thing that breaks the build rather than fixes it.
  #
  # gtksourceview3 alongside gtksourceviewmm: the C++ bindings' .pc file
  # Requires: the C library's, and pkg-config fails the whole lookup — with
  # "Package 'gtksourceview-3.0' ... not found", not a missing-header error —
  # if only the bindings are present.
  microtex = pkgs.stdenv.mkDerivation {
    pname = "microtex";
    version = "0-unstable-2026-06-05";
    src = inputs.microtex;

    nativeBuildInputs = with pkgs; [ cmake pkg-config ];
    buildInputs = with pkgs; [
      tinyxml-2
      gtkmm3
      gtksourceviewmm
      gtksourceview3
      cairomm
      fontconfig
    ];

    # No install rules in CMakeLists at all — the PKGBUILD copies the two
    # artefacts out of the build tree by hand, and so does this. cmake's
    # configure step is what puts res/ next to the binary (`file(COPY res
    # DESTINATION .)`, CMakeLists.txt:49), so both live in the build dir,
    # which is where installPhase runs.
    installPhase = ''
      runHook preInstall
      install -Dm0755 LaTeX $out/opt/MicroTeX/LaTeX
      cp -r res $out/opt/MicroTeX/res
      runHook postInstall
    '';

    # The one thing worth checking is the mode the shells actually use, since
    # a GUI-only build would still install cleanly and fail at runtime with
    # nothing on screen.
    doInstallCheck = true;
    installCheckPhase = ''
      cd $out/opt/MicroTeX
      ./LaTeX -headless '-input=\frac{a}{b}' -output=$TMPDIR/check.svg \
        -textsize=16 -padding=4 -maxwidth=0.85
      grep -q "<svg" $TMPDIR/check.svg
    '';

    meta = {
      description = "LaTeX rendering engine used by the illogical-impulse shells";
      homepage = "https://github.com/end-4/MicroTeX";
      license = pkgs.lib.licenses.mit;
      mainProgram = "LaTeX";
    };
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
    [ -n "$img" ] && [ -f "$img" ] || { passthrough; exit 0; }
    case "$img" in
      *.mp4|*.webm|*.mkv|*.avi|*.mov|*.MP4|*.WEBM|*.MKV|*.AVI|*.MOV)
        passthrough; exit 0 ;;
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
    sed -i 's|home_dir \.\. "/.local/state/quickshell/.venv"|"${venv}"|' \
      $out/.config/hypr/hyprland/env.lua
    grep -q '${venv}' $out/.config/hypr/hyprland/env.lua

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

    # MicroTeX. Both shells hardcode /opt/MicroTeX and then `cd` into it, so
    # the store path replaces the whole directory and the `cd` still works —
    # see the derivation above for why the cwd matters. Counted rather than
    # globbed blindly: this is a silent failure if it misses, because a
    # missing renderer shows up as an AI reply with a blank where the formula
    # should be, and nothing in any log.
    latexRenderers=$(grep -rIl 'microtexBinaryDir' $out/.config/quickshell | wc -l)
    [ "$latexRenderers" = "2" ] || {
      echo "LatexRenderer.qml: expected one per shell, found $latexRenderers" >&2
      exit 1
    }
    grep -rIlZ '"/opt/MicroTeX"' $out/.config/quickshell \
      | xargs -0 -r sed -i 's|"/opt/MicroTeX"|"${microtex}/opt/MicroTeX"|'
    [ "$(grep -rIo '${microtex}/opt/MicroTeX' $out/.config/quickshell | wc -l)" = "2" ] || exit 1

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
    done

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

  # Paths that stay one definition across both sessions. The comment on
  # home.file says why these three and nothing else.
  sharedFromSessionA = [ "git" "menus" "mimeapps.list" "dconf" ];

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
  # recursive = true, for the same reason ../home/caelestia.nix needs it: a
  # plain directory source symlinks the whole tree read-only, and then nothing
  # can create hypr/custom/*.lua or illogical-impulse/config.json at runtime.
  # recursive makes real directories and symlinks the files individually.

  # ── Tooling that both sessions must agree on.
  #
  # Session B reads ~/.config-ii, so everything home-manager writes into
  # ~/.config is invisible here. For the dots that is the point — ii ships its
  # own fish, kitty, foot, fontconfig, gtk-3.0 and starship.toml, and the
  # caelestia/uwsm/systemd entries are session A's business. But three of them
  # are not look-and-feel, and losing them breaks work rather than changing
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
    # The three shared paths, linked at their live ~/.config location.
    // lib.listToAttrs (map (name:
      lib.nameValuePair "${cfgDirName}/${name}" {
        source = config.lib.file.mkOutOfStoreSymlink
          "${config.home.homeDirectory}/.config/${name}";
      }) sharedFromSessionA);

  # ── VS Code follows the session's light/dark, in session B too.
  #
  # ../home/vscode.nix already solves this for session A: vscode-theme-settings
  # asserts window.autoDetectColorScheme plus the preferred light and dark
  # themes into Code/User/settings.json, editing the JSONC in place rather than
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
      import ./vscode-theme-settings.nix { inherit pkgs; }
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
    venv
    # No microtex here: nothing runs it from PATH. The QML is pointed at its
    # store path in `dots` above, and that reference is what keeps it alive —
    # putting it in the profile would only add an ~/.nix-profile/opt/MicroTeX
    # nobody looks at.
    autoLightDarkCtl # `ii-lightdark-auto [status|on|off|toggle]`
    plasmaApplyColorscheme # see ./ii-plasma-apply-colorscheme.py

    # No fonts here on purpose — they are system-wide in
    # ../modules/ii-session.nix. home-manager advertises profile fonts through
    # ~/.config/fontconfig/conf.d/10-hm-fonts.conf, which lives in the config
    # root session B does not read, so a font in this list would be invisible
    # in the one session that wants it. google-fonts would also collide here
    # with the rubik that ../home/caelestia.nix already installs: both ship
    # share/fonts/truetype/Rubik[wght].ttf from different store paths, and
    # buildEnv refuses that.

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
    kdePackages.systemsettings
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
    kdePackages.kcmutils
  ];
}
