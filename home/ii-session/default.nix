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
  kde = import ./kde.nix args;
  inherit (kde) plasmaTools kcmHosts;
  capture = import ./capture.nix args;
  display = import ./display-power.nix args;
  inherit (display) displayPower;
  keybinds = import ./keybinds.nix args;
  inherit (keybinds) volumeControlToggle;
  restart = import ./shell-restart.nix args;
  clipboard = import ./clipboard.nix args;
  ai = import ./ai.nix args;
  video = import ./video-wallpaper.nix args;
  inherit (video) videoFrame videoProxy;

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
${kde.patch}
    # ── Which shell starts.
    sed -i 's|hl.env("qsConfig", "ii")|hl.env("qsConfig", "${qsConfig}")|' \
      $out/.config/hypr/hyprland/variables.lua
    grep -q 'hl.env("qsConfig", "${qsConfig}")' $out/.config/hypr/hyprland/variables.lua

${keybinds.patch}
${capture.patch}
${display.patch}
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

${video.patch}
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

    cat >> $out/.config/hypr/hyprland/rules.lua <<'IIRULES'

-- Bar islands are 65% opaque over the wallpaper; blur them anyway, and blur what is really
-- behind them: xray reads the blur cache, which is off under a video wallpaper, and then blurs
-- black, so bright wallpaper gave near-black islands (NixOS config, ii-session.nix)
hl.layer_rule({ match = { namespace = "quickshell:bar" }, ignore_alpha = 0.3 })
hl.layer_rule({ match = { namespace = "quickshell:verticalBar" }, ignore_alpha = 0.3 })
hl.layer_rule({ match = { namespace = "quickshell:bar" }, xray = false })
hl.layer_rule({ match = { namespace = "quickshell:verticalBar" }, xray = false })
IIRULES

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

${clipboard.patch}
${restart.patch}
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

${ai.patch}
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
