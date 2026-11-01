OskControlButton { // Drag handle: floating only, a pinned keyboard is docked
    opacity: root.pinned ? 0.4 : 1
    contentItem: MaterialSymbol {
        horizontalAlignment: Text.AlignHCenter
        text: "drag_indicator"
        iconSize: Appearance.font.pixelSize.larger
    }
    MouseArea {
        id: dragArea
        anchors.fill: parent
        enabled: !root.pinned
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        // The pointer is tracked in the window's coordinates, not the
        // handle's: the handle moves with the keyboard, so its own
        // coordinates would feed the motion back into itself.
        property point grab: Qt.point(0, 0)
        property real startX: 0
        property real startY: 0
        onPressed: (mouse) => {
            grab = mapToItem(oskRoot.contentItem, mouse.x, mouse.y)
            startX = root.dragX
            startY = root.dragY
        }
        onPositionChanged: (mouse) => {
            if (!pressed) return
            const p = mapToItem(oskRoot.contentItem, mouse.x, mouse.y)
            const maxX = (oskRoot.width - oskBackground.width) / 2
            const maxDown = Appearance.sizes.elevationMargin
            const maxUp = oskRoot.height - oskBackground.height - Appearance.sizes.elevationMargin
            root.dragX = Math.max(-maxX, Math.min(maxX, startX + p.x - grab.x))
            root.dragY = Math.max(-maxUp, Math.min(maxDown, startY + p.y - grab.y))
        }
    }
}
