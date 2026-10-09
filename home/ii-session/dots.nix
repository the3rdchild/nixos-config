# ── The merged, patched config tree.
#
# ii supplies the whole install (hypr config, scripts, matugen templates, the
# app configs); end4-pC is dropped in beside ii's quickshell config as a
# second config root, which is exactly how its README says to install it.
#
# What is here is what makes upstream run on NixOS at all; every feature's
# own patch comes from its file, in the order `patches` lists them. Each
# patch checks its anchors, so an upstream change fails the build rather
# than applying half of it.
{ pkgs, lib, inputs, qsConfig, cfgDirName, patches, ... }:
pkgs.runCommand "illogical-impulse-nixos" { } ''
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

  # ── Helpers for the patches below.
  #
  # Most patches touch only the shell that runs, end4-pC: ii's copies of
  # the same files have drifted from it, so one set of anchors cannot
  # cover both.
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

  # ── The features.
  ${lib.concatStringsSep "\n" patches}

  # ── Upstream gaps.
  #
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

  # Bluetooth pairing agent. ../../modules/bluetooth.nix enables blueman, but
  # its applet is a D-Bus/systemd user unit nothing in this session starts,
  # and kded6 — whose bluedevil module is the other agent — is killed by
  # ConflictKiller.qml. With no agent, pairing a device that asks for a PIN
  # or confirmation fails silently. Started from here so it inherits the
  # session's WAYLAND_DISPLAY.
  sed -i '/^    hl.exec_cmd("easyeffects --hide-window --service-mode")$/a\    hl.exec_cmd("blueman-applet")' \
    $out/.config/hypr/hyprland/execs.lua
  grep -q '^    hl.exec_cmd("blueman-applet")$' $out/.config/hypr/hyprland/execs.lua

  # ── The config root rewrite. Must be last: it rewrites every patch's
  # output along with upstream's.
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
''
