pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// Per-output settings for whichever monitor DisplayPage selected.
//
// Every control here goes through applyChange(), which edits one output inside
// a full spec list and hands the whole list to Monitors.apply(). Changing a
// single output on its own makes Hyprland re-run the catch-all rule and reflow
// the others.
PageBase {
    id: root

    readonly property var monitor: Monitors.find(Monitors.selectedKey)

    readonly property string resolution: monitor ? `${monitor.width}x${monitor.height}` : ""
    readonly property list<string> resolutions: monitor ? Monitors.resolutionsFor(monitor) : []
    readonly property list<string> refreshRates: monitor ? Monitors.refreshRatesFor(monitor, resolution) : []

    // Hyprland rejects a scale that does not divide the mode into a whole
    // number of logical pixels, so offer the fractions that are actually
    // reachable rather than a free slider that mostly errors.
    readonly property list<real> scales: [1, 1.25, 1.5, 1.75, 2]
    readonly property list<int> transforms: [0, 1, 2, 3]

    // Mirroring is by port name — Hyprland's `mirror` key does not take desc:.
    readonly property list<var> mirrorTargets: Monitors.list.filter(m => monitor && m.name !== monitor.name && m.disabled !== true)

    function applyChange(mutate: var): void {
        const all = Monitors.specs();
        const spec = all.find(s => s.output === Monitors.selectedKey);
        if (!spec)
            return;
        mutate(spec);
        Monitors.apply(all, true);
    }

    function transformLabel(t: int): string {
        if (t === 1)
            return qsTr("90° clockwise");
        if (t === 2)
            return qsTr("180°");
        if (t === 3)
            return qsTr("270° clockwise");
        return qsTr("None");
    }

    title: monitor ? Monitors.labelFor(monitor) : qsTr("Display")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Resolution options for this output.
        Variants {
            id: resVariants

            model: root.resolutions

            MenuItem {
                required property string modelData

                text: modelData
                icon: modelData === root.resolution ? "check" : ""
                activeIcon: "aspect_ratio"
            }
        }

        Variants {
            id: rateVariants

            model: root.refreshRates

            MenuItem {
                required property string modelData

                text: qsTr("%1 Hz").arg(Math.round(parseFloat(modelData) * 100) / 100)
                icon: root.monitor && Math.abs(parseFloat(modelData) - root.monitor.refreshRate) < 0.01 ? "check" : ""
                activeIcon: "refresh"
            }
        }

        Variants {
            id: scaleVariants

            model: root.scales

            MenuItem {
                required property real modelData

                text: qsTr("%1×").arg(modelData)
                icon: root.monitor && Math.abs(modelData - root.monitor.scale) < 0.001 ? "check" : ""
                activeIcon: "zoom_in"
            }
        }

        Variants {
            id: transformVariants

            model: root.transforms

            MenuItem {
                required property int modelData

                text: root.transformLabel(modelData)
                icon: root.monitor && (root.monitor.transform ?? 0) === modelData ? "check" : ""
                activeIcon: "screen_rotation"
            }
        }

        Variants {
            id: mirrorVariants

            // A leading null is the "off" entry; the menu is a flat list, so
            // the sentinel has to live in the model rather than beside it.
            model: [null].concat(root.mirrorTargets)

            MenuItem {
                required property var modelData

                text: modelData ? Monitors.labelFor(modelData) : qsTr("Off")
                icon: {
                    const cur = root.monitor && root.monitor.mirrorOf !== "none" ? root.monitor.mirrorOf : "";
                    return (modelData ? modelData.name : "") === (cur ?? "") ? "check" : "";
                }
                activeIcon: modelData ? "content_copy" : "crop_free"
            }
        }

        SectionHeader {
            first: true
            text: qsTr("Output")
        }

        InfoRow {
            first: true
            label: qsTr("Connector")
            value: root.monitor ? root.monitor.name : "—"
        }

        InfoRow {
            last: true
            label: qsTr("Identified as")
            // What the saved rule is keyed on. Worth showing: it is why the
            // projector and the TV can hold different settings on one port.
            value: Monitors.selectedKey
        }

        SectionHeader {
            text: qsTr("Mode")
        }

        ToggleRow {
            first: true
            text: qsTr("Enabled")
            subtext: qsTr("Turn this output off without unplugging it")
            checked: root.monitor ? root.monitor.disabled !== true : false
            onToggled: {
                const want = checked;
                // Never let the last display be switched off — recovering
                // needs a TTY.
                if (!want && Monitors.list.filter(m => m.disabled !== true).length <= 1) {
                    checked = true;
                    Monitors.lastError = qsTr("Refusing to disable the only active display.");
                    return;
                }
                root.applyChange(spec => spec.disabled = !want);
            }
        }

        SelectRow {
            label: qsTr("Resolution")
            subtext: qsTr("Modes reported by this display")
            menuItems: resVariants.instances
            active: resVariants.instances.find(i => i.text === root.resolution) ?? null
            fallbackText: root.resolution
            onSelected: item => {
                const res = item.text;
                if (res === root.resolution)
                    return;
                // The current rate may not exist at the new resolution, so
                // take the highest one that does rather than carrying over a
                // mode Hyprland will reject.
                const rates = Monitors.refreshRatesFor(root.monitor, res);
                const rate = rates.length ? rates[0] : "";
                root.applyChange(spec => spec.mode = rate ? `${res}@${rate}` : res);
            }
        }

        SelectRow {
            label: qsTr("Refresh rate")
            subtext: qsTr("Higher is smoother; costs battery on the built-in panel")
            menuItems: rateVariants.instances
            active: rateVariants.instances.find(i => root.monitor && Math.abs(parseFloat(i.text) - root.monitor.refreshRate) < 0.01) ?? null
            fallbackText: root.monitor ? qsTr("%1 Hz").arg(Math.round(root.monitor.refreshRate)) : ""
            onSelected: item => {
                const rate = root.refreshRates.find(r => Math.abs(parseFloat(r) - parseFloat(item.text)) < 0.01);
                if (rate)
                    root.applyChange(spec => spec.mode = `${root.resolution}@${rate}`);
            }
        }

        SelectRow {
            last: true
            label: qsTr("Scale")
            subtext: qsTr("Size of interface elements")
            menuItems: scaleVariants.instances
            active: scaleVariants.instances.find(i => root.monitor && Math.abs(parseFloat(i.text) - root.monitor.scale) < 0.001) ?? null
            fallbackText: root.monitor ? qsTr("%1×").arg(root.monitor.scale) : ""
            onSelected: item => {
                const scale = parseFloat(item.text);
                root.applyChange(spec => spec.scale = scale);
            }
        }

        SectionHeader {
            text: qsTr("Layout")
        }

        SelectRow {
            first: true
            label: qsTr("Rotation")
            subtext: qsTr("Useful for a display turned on its side")
            menuItems: transformVariants.instances
            active: transformVariants.instances[root.monitor ? root.transforms.indexOf(root.monitor.transform ?? 0) : 0] ?? null
            fallbackText: root.monitor ? root.transformLabel(root.monitor.transform ?? 0) : ""
            onSelected: item => {
                const idx = transformVariants.instances.indexOf(item);
                if (idx >= 0)
                    root.applyChange(spec => spec.transform = root.transforms[idx]);
            }
        }

        SelectRow {
            last: true
            label: qsTr("Duplicate from")
            subtext: qsTr("Show another display's image on this one")
            menuOnTop: true
            menuItems: mirrorVariants.instances
            active: {
                const cur = root.monitor && root.monitor.mirrorOf !== "none" ? root.monitor.mirrorOf : "";
                if (!cur)
                    return mirrorVariants.instances[0] ?? null;
                const target = root.mirrorTargets.find(m => m.name === cur);
                return target ? mirrorVariants.instances[root.mirrorTargets.indexOf(target) + 1] ?? null : null;
            }
            fallbackText: qsTr("Off")
            onSelected: item => {
                const idx = mirrorVariants.instances.indexOf(item);
                const target = idx > 0 ? root.mirrorTargets[idx - 1] : null;
                root.applyChange(spec => spec.mirrorOf = target ? target.name : "");
            }
        }
    }
}
