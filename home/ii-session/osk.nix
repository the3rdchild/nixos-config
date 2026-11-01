# ── On-screen keyboard: no function row, and it can be dragged.
#
# The function row (Esc, F1-F12, PrtSc, Del) is dropped from every layout.
# layouts.js is left alone: OskContent skips any row made only of `fn`-shaped
# keys, which is exactly that row in all three layouts, so a different layout
# stays a one-line change and upstream's file stays diffable.
#
# Dragging. The window used to be anchored bottom/left/right and as tall as
# the keyboard, so there was nowhere to drag it to. Now:
#
#   pinned    unchanged: docked at the bottom centre, reserving its space.
#   floating  anchored on all four edges — a transparent, screen-sized window
#             whose input mask is still only the keyboard, so everything
#             around it stays clickable — with the keyboard placed at the
#             bottom centre plus a drag offset.
#
# Pinning and dragging cannot both hold: an exclusive zone only works on a
# window anchored to one edge. So the handle is inert while pinned, and the
# offset is kept, so unpinning puts the keyboard back where it was left.
# The offset lives on the Scope, not the window, because the Loader destroys
# the window every time the keyboard closes; it does not outlive the shell.
{ pkgs, ... }: let
  handle = pkgs.writeText "ii-osk-drag-handle.qml" (builtins.readFile ./files/osk-drag-handle.qml);
in {
  patch = ''
    O=$qs/modules/ii/onScreenKeyboard

    substituteInPlace $O/OskContent.qml --replace-fail \
      'model: root.currentLayout.keys' \
      'model: root.currentLayout.keys.filter(row => !row.every(key => key.shape === "fn"))'

    # Nix strips four columns from every continuation line below.
    substituteInPlace $O/OnScreenKeyboard.qml \
      --replace-fail 'property bool pinned: Config.options?.osk.pinnedOnStartup ?? false' \
                     'property bool pinned: Config.options?.osk.pinnedOnStartup ?? false
        // Offset from the resting spot (bottom centre) the keyboard was dragged to.
        property real dragX: 0
        property real dragY: 0' \
      --replace-fail 'anchors {
                    bottom: true' \
                     'anchors {
                    top: !root.pinned
                    bottom: true' \
      --replace-fail 'anchors.centerIn: parent
                    color: Appearance.colors.colUiBackground' \
                     '// Docked: centred in a window as tall as the keyboard. Floating: the
                    // window is the whole screen, so sit at its bottom centre, offset by the drag.
                    x: Math.round((parent.width - width) / 2 + (root.pinned ? 0 : root.dragX))
                    y: Math.round(parent.height - height - Appearance.sizes.elevationMargin + (root.pinned ? 0 : root.dragY))
                    color: Appearance.colors.colUiBackground'
    insert_after $O/OnScreenKeyboard.qml '                    VerticalButtonGroup {' ${handle} '                        '

    [ "$(grep -c 'top: !root.pinned' $O/OnScreenKeyboard.qml)" = "1" ] || exit 1
    [ "$(grep -c 'root.dragX' $O/OnScreenKeyboard.qml)" = "3" ] || exit 1
    [ "$(grep -c 'drag_indicator' $O/OnScreenKeyboard.qml)" = "1" ] || exit 1
    grep -q 'key.shape === "fn"' $O/OskContent.qml
  '';
}
