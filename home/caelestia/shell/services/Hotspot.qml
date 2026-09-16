pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Mobile hotspot state, driven entirely through the `hotspot` script from
// modules/hotspot.nix. Everything that needs privileges or NetworkManager
// surgery lives there; this only runs it and parses `hotspot status`.
//
// Deliberately not wired into Nmcli's `nmcli monitor`: the AP interface is
// filtered out of Nmcli's device lists (see the patch in home/caelestia.nix),
// so nothing there changes when the hotspot flips. The Network page polls
// refresh() while visible, and every action refreshes on exit.
Singleton {
    id: root

    property bool enabled: false
    property bool starting: false
    property bool stopping: false
    property string ssid: ""
    property string password: ""
    property string band: ""
    property int channel: 0
    property string address: ""
    property int clients: 0
    property string staInterface: ""
    property int staChannel: 0
    property int staFreq: 0
    property string staProfile: ""
    property string pinned: ""
    property string error: ""
    property bool loaded: false

    // True from the moment an on/off is requested until its status readback
    // lands, so the switch cannot be flipped twice.
    readonly property bool busy: toggleProc.running || setProc.running || pendingRefresh

    property bool pendingRefresh: false
    property string pendingAction: ""

    readonly property string bandLabel: {
        if (!root.channel)
            return "";
        const ghz = root.band === "a" ? "5 GHz" : "2.4 GHz";
        return qsTr("%1 · channel %2").arg(ghz).arg(root.channel);
    }

    function refresh(): void {
        if (!statusProc.running)
            statusProc.running = true;
    }

    function setEnabled(on: bool): void {
        if (toggleProc.running)
            return;
        root.error = "";
        root.pendingAction = on ? "on" : "off";
        root.starting = on;
        root.stopping = !on;
        toggleProc.command = ["hotspot", root.pendingAction];
        toggleProc.running = true;
    }

    function toggle(): void {
        setEnabled(!root.enabled);
    }

    function setSsid(value: string): void {
        runSet("ssid", value);
    }

    function setPassword(value: string): void {
        runSet("password", value);
    }

    function runSet(key: string, value: string): void {
        if (setProc.running)
            return;
        root.error = "";
        setProc.command = ["hotspot", "set", key, value];
        setProc.running = true;
    }

    function parseStatus(text: string): void {
        const kv = {};
        for (const line of text.split("\n")) {
            const i = line.indexOf("=");
            if (i > 0)
                kv[line.slice(0, i)] = line.slice(i + 1);
        }

        const state = kv.state ?? "off";
        root.enabled = state === "on";
        root.starting = state === "starting";
        root.stopping = state === "stopping";
        root.ssid = kv.ssid ?? "";
        root.password = kv.psk ?? "";
        root.band = kv.band ?? "";
        root.channel = parseInt(kv.channel ?? "0") || 0;
        root.address = kv.address ?? "";
        root.clients = parseInt(kv.clients ?? "0") || 0;
        root.staInterface = kv.sta ?? "";
        root.staChannel = parseInt(kv.sta_channel ?? "0") || 0;
        root.staFreq = parseInt(kv.sta_freq ?? "0") || 0;
        root.staProfile = kv.sta_profile ?? "";
        root.pinned = kv.pinned ?? "";
        if (kv.error)
            root.error = kv.error;
        root.loaded = true;
    }

    // Same trick as VPN.qml: `exited` only fires for a process that actually
    // ran, so a running->false without it means the command was never found
    // (the module is not in this system generation). Surface that rather than
    // leaving a dead switch.
    property bool statusExited: false

    Process {
        id: statusProc

        command: ["hotspot", "status"]
        environment: ({
                LANG: "C.UTF-8",
                LC_ALL: "C.UTF-8"
            })
        stdout: StdioCollector {
            onStreamFinished: root.parseStatus(text)
        }
        onExited: { // qmllint disable signal-handler-parameters
            root.statusExited = true;
            root.pendingRefresh = false;
        }
        onRunningChanged: {
            if (running) {
                root.statusExited = false;
                return;
            }
            if (!root.statusExited) {
                root.error = qsTr("hotspot command not found");
                root.loaded = true;
                root.pendingRefresh = false;
            }
        }
    }

    Process {
        id: toggleProc

        environment: ({
                LANG: "C.UTF-8",
                LC_ALL: "C.UTF-8"
            })
        stderr: StdioCollector {
            id: toggleErr
        }
        onExited: exitCode => { // qmllint disable signal-handler-parameters
            if (exitCode !== 0) {
                const msg = toggleErr.text.trim().split("\n").pop() ?? "";
                root.error = msg.replace(/^hotspot: /, "") || qsTr("hotspot %1 failed").arg(root.pendingAction);
            }
            root.pendingAction = "";
            root.pendingRefresh = true;
            root.refresh();
        }
    }

    Process {
        id: setProc

        environment: ({
                LANG: "C.UTF-8",
                LC_ALL: "C.UTF-8"
            })
        stderr: StdioCollector {
            id: setErr
        }
        onExited: exitCode => { // qmllint disable signal-handler-parameters
            if (exitCode !== 0) {
                const msg = setErr.text.trim().split("\n").pop() ?? "";
                root.error = msg.replace(/^hotspot: /, "") || qsTr("could not save hotspot settings");
            }
            root.pendingRefresh = true;
            root.refresh();
        }
    }
}
