pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.utils

// Monitor configuration for the Nexus Display page.
//
// Two things make this less obvious than it looks:
//
//  1. Hyprland's Lua parser rejects `hyprctl keyword` outright ("keyword can't
//     work with non-legacy parsers. Use eval."), so live changes go through
//     `hyprctl eval hl.monitor{...}` instead. The legacy `keyword monitor`
//     form is kept for people not on a Lua config.
//
//  2. `eval` is runtime-only — it does not survive a reload. Persistence is a
//     separate write to ~/.config/hypr/monitors.lua, which hypr-user.lua
//     loads on every config load. That is the same file nwg-displays writes,
//     deliberately: one format, two editors, no migration.
//
// Outputs are keyed on `desc:<edid description>` rather than port name. A
// laptop that meets both a TV and a projector sees both as HDMI-A-1, and a
// name-keyed rule would push the TV's refresh rate onto a projector that
// cannot display it.
Singleton {
    id: root

    // Snapshot of `hyprctl -j monitors all`. Includes disabled outputs, which
    // plain `monitors` omits — needed for the enable/disable toggle to be able
    // to show something that is currently off.
    property var list: []
    property bool ready
    property string lastError

    // Which output the detail sub-page is editing. Kept here rather than on
    // NexusState so this feature stays confined to files it owns.
    property string selectedKey

    readonly property string confDir: `${Quickshell.env("XDG_CONFIG_HOME") || `${Paths.home}/.config`}/hypr`
    readonly property string confPath: `${confDir}/monitors.lua`

    readonly property bool usingLua: Hyprland.usingLua

    signal applied

    function refresh(): void {
        queryProc.running = true;
    }

    // Stable identity for an output. Falls back to the port name when the EDID
    // has no description — rare, but a virtual/headless output can hit it, and
    // a rule with an empty desc: would match everything.
    function keyFor(m: var): string {
        const desc = (m.description ?? "").trim();
        return desc ? `desc:${desc}` : m.name;
    }

    // Human label. `description` repeats the make in most EDIDs, so prefer the
    // model when it is present and distinct.
    function labelFor(m: var): string {
        const model = (m.model ?? "").trim();
        const make = (m.make ?? "").trim();
        if (model && make && !model.startsWith(make))
            return `${make} ${model}`;
        return model || (m.description ?? "").trim() || m.name;
    }

    // "1920x1080@180.00Hz" -> "1920x1080@180.00". Hyprland accepts the mode
    // with or without the suffix, but the suffix is not valid inside a Lua
    // spec string, so it is stripped once here rather than at every call site.
    function normaliseMode(mode: string): string {
        return (mode ?? "").replace(/Hz$/, "").trim();
    }

    function resolutionsFor(m: var): list<string> {
        const seen = [];
        for (const mode of m.availableModes ?? []) {
            const res = normaliseMode(mode).split("@")[0];
            if (res && !seen.includes(res))
                seen.push(res);
        }
        // Sort by pixel count, largest first — matches how every other display
        // panel orders resolutions, and puts the native mode at the top.
        return seen.sort((a, b) => {
            const [aw, ah] = a.split("x").map(Number);
            const [bw, bh] = b.split("x").map(Number);
            return bw * bh - aw * ah;
        });
    }

    function refreshRatesFor(m: var, resolution: string): list<string> {
        const seen = [];
        for (const mode of m.availableModes ?? []) {
            const parts = normaliseMode(mode).split("@");
            if (parts[0] !== resolution || !parts[1])
                continue;
            // EDIDs routinely advertise the same rate several times over
            // (120.00 twice, 119.88 twice on this TV). Dedupe on the rounded
            // value so the dropdown isn't four identical-looking entries.
            const rounded = Math.round(parseFloat(parts[1]) * 100) / 100;
            if (!seen.some(r => Math.abs(parseFloat(r) - rounded) < 0.01))
                seen.push(parts[1]);
        }
        return seen.sort((a, b) => parseFloat(b) - parseFloat(a));
    }

    function currentModeFor(m: var): string {
        return `${m.width}x${m.height}@${m.refreshRate.toFixed(2)}`;
    }

    // Build the desired-state spec for one output from the live snapshot, so
    // callers only have to describe what they are changing.
    function specFor(m: var): var {
        return {
            output: keyFor(m),
            name: m.name,
            disabled: m.disabled === true,
            mode: currentModeFor(m),
            x: m.x,
            y: m.y,
            scale: m.scale,
            transform: m.transform ?? 0,
            mirrorOf: m.mirrorOf && m.mirrorOf !== "none" ? m.mirrorOf : ""
        };
    }

    function specs(): var {
        return list.map(m => specFor(m));
    }

    // Lua string escaping. Descriptions are EDID strings and can in principle
    // contain a quote or a backslash; one bad description would otherwise be a
    // syntax error that takes out the whole monitors.lua on next load.
    function luaStr(s: string): string {
        return `"${(s ?? "").replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;
    }

    function luaFor(spec: var): string {
        const props = [`output = ${luaStr(spec.output)}`];

        if (spec.disabled) {
            props.push("disabled = true");
        } else {
            props.push(`mode = ${luaStr(spec.mode)}`);
            props.push(`position = ${luaStr(`${spec.x}x${spec.y}`)}`);
            props.push(`scale = ${spec.scale}`);
            if (spec.transform)
                props.push(`transform = ${spec.transform}`);
            if (spec.mirrorOf)
                props.push(`mirror = ${luaStr(spec.mirrorOf)}`);
        }

        return `hl.monitor({ ${props.join(", ")} })`;
    }

    // Legacy .conf form, for a non-Lua Hyprland config.
    function keywordFor(spec: var): string {
        if (spec.disabled)
            return `keyword monitor ${spec.output},disable`;

        let line = `keyword monitor ${spec.output},${spec.mode},${spec.x}x${spec.y},${spec.scale}`;
        if (spec.mirrorOf)
            line += `,mirror,${spec.mirrorOf}`;
        if (spec.transform)
            line += `,transform,${spec.transform}`;
        return line;
    }

    // Apply every output in one batch, always.
    //
    // Applying one at a time looks like it should work and does not: the
    // catch-all `hl.monitor{ position = "auto" }` in the base config re-runs
    // on each change and reflows everything else. Setting just the external
    // display here moved the laptop panel from 0x0 to 3840x0.
    function apply(allSpecs: var, persist: bool): void {
        if (!allSpecs.length)
            return;

        const cmds = allSpecs.map(s => usingLua ? `eval ${luaFor(s)}` : keywordFor(s));
        applyProc.command = ["hyprctl", "--batch", cmds.join(" ; ")];
        applyProc.pendingPersist = persist ? allSpecs : null;
        applyProc.running = true;
    }

    // Drop the saved layout. The current session keeps whatever is applied
    // right now — only the next reload changes, falling back to the automatic
    // placement in hypr-user.lua.
    function forget(): void {
        confFile.setText("");
        confFile.remove();
    }

    function persist(allSpecs: var): void {
        const header = "-- Written by the Caelestia Nexus Display page.\n" + "-- Loaded by ~/.config/caelestia/hypr-user.lua. Same format nwg-displays\n" + "-- emits, so either tool can rewrite this file.\n";
        confFile.setText(header + allSpecs.map(s => luaFor(s)).join("\n") + "\n");
    }

    function find(key: string): var {
        return list.find(m => keyFor(m) === key) ?? null;
    }

    // Panels wired to the board rather than a cable. Used to decide which
    // output the arrangement presets treat as "this machine's screen".
    function isInternal(m: var): bool {
        return /^(eDP|LVDS|DSI)/i.test(m.name ?? "");
    }

    // ── Arrangement presets (the Win+P set).
    //
    // Each returns a full spec list, because apply() is all-or-nothing. Every
    // preset re-asserts position for every output: leaving one unset lets the
    // catch-all's position="auto" reflow it somewhere unexpected.
    function presetExtend(externalOnRight: bool): var {
        const all = specs();
        const internal = all.filter(s => isInternal(find(s.output)));
        const external = all.filter(s => !isInternal(find(s.output)));

        // Nothing internal (desktop, or lid shut) — just lay them out in the
        // order Hyprland reports and leave it at that.
        const ordered = internal.length ? (externalOnRight ? internal.concat(external) : external.concat(internal)) : all;

        let x = 0;
        for (const spec of ordered) {
            spec.disabled = false;
            spec.mirrorOf = "";
            spec.x = x;
            spec.y = 0;
            x += Math.round(widthOf(spec) / spec.scale);
        }
        return ordered;
    }

    function presetMirror(): var {
        const all = specs();
        const internal = all.find(s => isInternal(find(s.output)));
        const source = internal ?? all[0];
        if (!source)
            return all;

        for (const spec of all) {
            spec.disabled = false;
            spec.x = 0;
            spec.y = 0;
            // Hyprland mirrors by port name, not description — `mirror` takes
            // a monitor name and desc: is not accepted there.
            spec.mirrorOf = spec.output === source.output ? "" : source.name;
        }
        return all;
    }

    function presetOnly(internalOnly: bool): var {
        const all = specs();
        const keep = all.filter(s => isInternal(find(s.output)) === internalOnly);

        // Refuse to turn off every screen. Without this, "External only" with
        // nothing plugged in blanks the machine and the only way back is a TTY.
        if (!keep.length)
            return all;

        for (const spec of all) {
            const on = keep.includes(spec);
            spec.disabled = !on;
            spec.mirrorOf = "";
            if (on) {
                spec.x = 0;
                spec.y = 0;
            }
        }
        return all;
    }

    function widthOf(spec: var): int {
        const w = parseInt(spec.mode.split("@")[0].split("x")[0], 10);
        // Rotated 90/270 swaps the axis the layout advances along.
        if (spec.transform === 1 || spec.transform === 3 || spec.transform === 5 || spec.transform === 7) {
            const h = parseInt(spec.mode.split("@")[0].split("x")[1], 10);
            return isNaN(h) ? 0 : h;
        }
        return isNaN(w) ? 0 : w;
    }

    // Hyprland renumbers and reorders outputs on hotplug, so re-read rather
    // than patching the cached list.
    Connections {
        function onRawEvent(event: HyprlandEvent): void {
            const n = event.name;
            if (n === "monitoradded" || n === "monitorremoved" || n === "monitoraddedv2" || n === "monitorremovedv2")
                root.refresh();
        }

        target: Hyprland
    }

    Process {
        id: queryProc

        command: ["hyprctl", "-j", "monitors", "all"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.list = JSON.parse(text);
                    root.lastError = "";
                    root.ready = true;
                } catch (e) {
                    root.lastError = qsTr("Could not read monitor list: %1").arg(e);
                }
            }
        }
    }

    Process {
        id: applyProc

        property var pendingPersist

        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim())
                    root.lastError = text.trim();
            }
        }

        onExited: exitCode => {
            if (exitCode === 0 && pendingPersist)
                root.persist(pendingPersist);
            pendingPersist = null;
            // Hyprland needs a moment to settle a mode switch before the new
            // geometry shows up in `hyprctl monitors`.
            settleTimer.restart();
        }
    }

    Timer {
        id: settleTimer

        interval: 500
        onTriggered: {
            root.refresh();
            root.applied();
        }
    }

    FileView {
        id: confFile

        path: root.confPath
        // No saved layout yet is the normal first-run state, not an error
        // worth a warning on every shell start.
        printErrors: false
        atomicWrites: true
    }

    Component.onCompleted: refresh()
}
