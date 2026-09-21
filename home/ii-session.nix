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
    "hypr/hyprland/shellOverrides"
    "hypr/hyprland/colors.lua"
    "hypr/hyprlock/colors.conf"
    "hypr/monitors.lua"
    "matugen/config.toml"
    "fuzzel/fuzzel_theme.ini"
    "gtk-3.0/gtk.css"
    "gtk-4.0/gtk.css"
  ];

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
  home.file.${cfgDirName} = {
    source = linked;
    recursive = true;
  };

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
  # Not packaged anywhere and therefore missing: microtex (LaTeX rendering in
  # the shell degrades to nothing), breeze-plus, qt6-avif-image-plugin.
  home.packages = with pkgs; [
    venv

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
    libcava
    lxqt.pavucontrol-qt

    # Screen capture.
    hyprshot
    slurp
    swappy
    wf-recorder
    tesseract

    # Basic tools the scripts assume.
    bc
    gojq
    yq-go
    rsync
    eza

    # Qt/GTK theming the dots ship configs for.
    adw-gtk3
    kdePackages.breeze
    kdePackages.breeze-icons
    kdePackages.systemsettings
    kdePackages.plasma-nm
    kdePackages.bluedevil
  ];
}
