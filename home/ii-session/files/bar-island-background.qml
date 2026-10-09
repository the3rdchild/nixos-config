
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
