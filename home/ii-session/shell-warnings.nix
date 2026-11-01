# ── Two upstream QML warnings that repeat for as long as the shell runs.
#
# VerticalBarContent assigns `item.mirrored` to every bar widget that has a
# `mirrored` property. That is meant for the visualizer, the only widget
# where it is a plain `property bool mirrored: false`; any widget built on a
# QtQuick Control (the launcher and power buttons) has `mirrored` too, but
# read-only, and each assignment threw "Cannot assign to read-only property"
# every time the bar reloaded. The value is false for everything but a
# visualizer after an odd number of visualizers, and false is the default,
# so only assigning when it is true leaves the visualizer exactly as it was
# and never touches the others.
#
# StyledPopup.shouldShow is declared `bool` but starts with
# `root.hoverTarget && ...`, which is undefined while nothing is hovered, so
# every popup warned "Unable to assign [undefined] to bool" on creation.
{ ... }: {
  patch = ''
    V=$qs/modules/ii/verticalBar/VerticalBarContent.qml
    [ "$(grep -cE '^ +item\.mirrored = root\.getMirroredForIndex\(.*\)$' $V)" = "6" ] || {
      echo "$V: expected six item.mirrored assignments" >&2
      exit 1
    }
    sed -i -E 's/^( +)item\.mirrored = (root\.getMirroredForIndex\(.*\))$/\1if (\2) item.mirrored = true/' $V
    [ "$(grep -c ') item.mirrored = true$' $V)" = "6" ] || exit 1

    substituteInPlace $qs/modules/common/widgets/StyledPopup.qml --replace-fail \
      'shouldShow: root.hoverTarget && root.hoverTarget.containsMouse &&' \
      'shouldShow: !!root.hoverTarget && !!root.hoverTarget.containsMouse &&'
  '';
}
