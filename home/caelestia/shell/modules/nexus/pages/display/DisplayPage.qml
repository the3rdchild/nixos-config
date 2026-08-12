pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.nexus.common

// Display settings: one row per output, plus the arrangement presets.
//
// Per-output detail lives in MonitorDetail (sub-page 1). Everything here acts
// on all outputs at once, because Hyprland reflows the whole layout whenever
// any single output changes — see Monitors.apply().
PageBase {
    id: root

    title: qsTr("Display")

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        SectionHeader {
            first: true
            text: qsTr("Displays")
        }

        Repeater {
            id: monitorList

            model: Monitors.list

            NavRow {
                id: monitorRow

                required property var modelData
                required property int index

                readonly property bool off: modelData.disabled === true

                first: index === 0
                last: index === monitorList.count - 1

                icon: Monitors.isInternal(modelData) ? "laptop" : modelData.mirrorOf && modelData.mirrorOf !== "none" ? "content_copy" : "monitor"
                text: Monitors.labelFor(modelData)

                subtext: {
                    if (off)
                        return qsTr("%1 — off").arg(modelData.name);
                    if (modelData.mirrorOf && modelData.mirrorOf !== "none")
                        return qsTr("%1 — mirroring %2").arg(modelData.name).arg(modelData.mirrorOf);

                    const hz = Math.round(modelData.refreshRate);
                    const scale = modelData.scale !== 1 ? qsTr(", %1× scale").arg(modelData.scale) : "";
                    return qsTr("%1 — %2×%3 at %4 Hz%5").arg(modelData.name).arg(modelData.width).arg(modelData.height).arg(hz).arg(scale);
                }

                onClicked: {
                    Monitors.selectedKey = Monitors.keyFor(modelData);
                    root.nState.openSubPage(1);
                }
            }
        }

        // No outputs at all means hyprctl failed or has not answered yet —
        // an empty list with no explanation reads as a broken page.
        Loader {
            Layout.fillWidth: true
            active: !Monitors.list.length
            visible: active

            sourceComponent: ConnectedRect {
                first: true
                last: true
                implicitHeight: emptyText.implicitHeight + Tokens.padding.large * 2

                StyledText {
                    id: emptyText

                    anchors.centerIn: parent
                    width: parent.width - Tokens.padding.largeIncreased * 2
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    color: Colours.palette.m3outline
                    font: Tokens.font.body.small
                    text: Monitors.ready ? qsTr("No outputs reported by Hyprland.") : qsTr("Reading outputs…")
                }
            }
        }

        SectionHeader {
            text: qsTr("Arrangement")
        }

        NavRow {
            first: true
            icon: "splitscreen_right"
            text: qsTr("Extend to the right")
            subtext: qsTr("External displays placed right of this screen")
            onClicked: Monitors.apply(Monitors.presetExtend(true), true)
        }

        NavRow {
            icon: "splitscreen_left"
            text: qsTr("Extend to the left")
            subtext: qsTr("External displays placed left of this screen")
            onClicked: Monitors.apply(Monitors.presetExtend(false), true)
        }

        // NOTE: there is deliberately no "Duplicate" preset here.
        //
        // Mirroring segfaults Hyprland. The backtrace lands in
        // Render::IHyprRenderer::damageMirrorsWith, reached from renderMonitor
        // -> CMonitorFrameScheduler::onFrame, i.e. the compositor dies on the
        // first frame it composites for a mirrored output. It takes the whole
        // session with it and drops you in Safe Mode.
        //
        // This is a longstanding upstream bug class, not something this page
        // can work around: hyprwm/Hyprland#854, #980, #1281, #7181, and
        // discussion #13517 — the last being "hyprpaper makes Hyprland crash
        // when starting monitor mirroring", which is our exact shape, since
        // caelestia also draws a per-screen background layer.
        //
        // "External only" below is the safe way to drive a projector.
        // Re-test with `hyprctl keyword monitor <name>,preferred,auto,1,mirror,eDP-1`
        // on a Hyprland bump; if it survives a frame, restore this preset and
        // the "Duplicate from" row in MonitorDetail.qml.

        NavRow {
            icon: "laptop"
            text: qsTr("This screen only")
            subtext: qsTr("Turn off external displays")
            onClicked: Monitors.apply(Monitors.presetOnly(true), true)
        }

        NavRow {
            last: true
            icon: "monitor"
            text: qsTr("External only")
            subtext: qsTr("Turn off the built-in screen")
            onClicked: Monitors.apply(Monitors.presetOnly(false), true)
        }

        SectionHeader {
            text: qsTr("Saved layout")
        }

        NavRow {
            first: true
            icon: "save"
            text: qsTr("Save current layout")
            subtext: qsTr("Reapplied on every Hyprland reload")
            onClicked: Monitors.persist(Monitors.specs())
        }

        NavRow {
            last: true
            icon: "restart_alt"
            text: qsTr("Forget saved layout")
            subtext: qsTr("Fall back to automatic placement at highest refresh rate")
            onClicked: Monitors.forget()
        }

        // Surfaced rather than logged: a rejected mode is the single most
        // likely thing to go wrong here, and silently reverting to the old
        // one looks like the page simply ignored the click.
        Loader {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.medium
            active: !!Monitors.lastError
            visible: active

            sourceComponent: ConnectedRect {
                first: true
                last: true
                color: Colours.palette.m3errorContainer
                implicitHeight: errLayout.implicitHeight + Tokens.padding.large * 2

                RowLayout {
                    id: errLayout

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Tokens.padding.largeIncreased
                    anchors.rightMargin: Tokens.padding.largeIncreased
                    spacing: Tokens.spacing.medium

                    MaterialIcon {
                        text: "error"
                        color: Colours.palette.m3onErrorContainer
                        fontStyle: Tokens.font.icon.medium
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: Monitors.lastError
                        color: Colours.palette.m3onErrorContainer
                        font: Tokens.font.label.small
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }

    // The snapshot goes stale while the page is closed — hotplug events are
    // handled in the service, but a mode changed from nwg-displays or the CLI
    // is not signalled at all.
    Component.onCompleted: Monitors.refresh()
}
