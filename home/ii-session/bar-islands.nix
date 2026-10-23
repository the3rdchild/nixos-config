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
# unblurred; the bar layers get 0.3 (the rules.lua append at the end). They
# also get xray off: xray blurs the blur cache, which is off under a video,
# so the islands were blurring black, not the wallpaper.
{ pkgs, fill, ... }: let
  barRegionsGrid = pkgs.writeShellScript "ii-bar-regions-grid" ''
    set -eu
    ${pkgs.imagemagick}/bin/magick identify -ping -format '%w %h\n' "$1[0]"
    ${pkgs.imagemagick}/bin/magick "$1[0]" -strip -background black -alpha remove -alpha off \
      -resize "$2!" -depth 8 -compress none ppm:-
  '';

  barIslandQml = {
    service = pkgs.writeText "WallpaperRegions.qml" (fill ./files/WallpaperRegions.qml {
      inherit barRegionsGrid;
    });

    # BarGroup.qml, after bgColor.
    props = pkgs.writeText "ii-bar-island-props.qml" (builtins.readFile ./files/bar-island-props.qml);

    # BarGroup.qml, before `background`, so it is drawn under it: background
    # keeps the segmented border and goes transparent while this is painted.
    background = pkgs.writeText "ii-bar-island-background.qml" (builtins.readFile ./files/bar-island-background.qml);
  };
in {
  patch = ''
    cp ${barIslandQml.service} $qs/services/WallpaperRegions.qml
    G=$qs/modules/ii/bar/BarGroup.qml
    substituteInPlace $G \
      --replace-fail 'import QtQuick.Layouts' 'import QtQuick.Layouts
    import Quickshell
    import qs.services' \
      --replace-fail '                            ? Appearance.colors.colUiBackground' \
                     '                            ? (root.islandPainted ? "transparent" : Appearance.colors.colUiBackground)'
    insert_after $G '    property color bgColor: Appearance.colors.colPrimaryContainer' ${barIslandQml.props} '    '
    insert_after $G '    default property alias items: gridLayout.children' ${barIslandQml.background} '    '
    [ "$(grep -c '^import Quickshell$' $G)" = "1" ] || exit 1
    [ "$(grep -c 'root.islandPainted' $G)" = "2" ] || exit 1

    # Segmented groups without their outline. Upstream draws a 1px border
    # round every segment and overlaps neighbours by the border's width
    # (-1, and -2 on the vertical bar) so adjacent borders coincide. With no
    # border the overlap would be a seam instead: two translucent islands
    # stacked on one line of pixels. So segments butt up against each other.
    # Only the default is dropped: a border width chosen for a widget in the
    # style editor (style.borderWidth) is explicit and stays.
    substituteInPlace $G \
      --replace-fail 'root.style?.borderWidth ?? (root.paintBackground && root.isSegmented && !root.isMaterial ? 1 : 0)' \
                     'root.style?.borderWidth ?? 0'
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
  '';
}
