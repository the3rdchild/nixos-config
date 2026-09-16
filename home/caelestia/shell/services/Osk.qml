pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// On-screen keyboard (wvkbd), owned by the shell.
//
// wvkbd has no IPC and never reports whether it is on screen: it is a
// layer-shell surface that flips visibility on SIGUSR1 (hide) / SIGUSR2
// (show) / SIGRTMIN (toggle). So the shell starts it as its own child, sends
// the explicit show/hide signals, and `visible` is the record of the last
// one sent. Everything that needs the state - the bar's status icon, the
// SUPER+SHIFT+K bind through `caelestia shell osk toggle` - goes through
// here, which is what keeps the two in sync.
//
// The process is started on first show (nothing runs at login) and kept
// alive hidden afterwards, so every later show is instant. It exits with
// the shell only when the shell is stopped cleanly: the unit's
// KillMode=process leaves children alive, and ExecStopPost in
// home/caelestia.nix reaps this one along with the nmcli monitors. The
// pkill on load covers the plain-session restart path (`qs -c caelestia
// kill`), where no unit runs and an orphan would otherwise stay on screen
// with nothing able to reach it.
Singleton {
    id: root

    property bool visible: false
    readonly property bool running: proc.running

    function show(): void {
        if (proc.running)
            proc.signal(12); // SIGUSR2
        else
            proc.running = true; // starts visible
        root.visible = true;
    }

    function hide(): void {
        if (proc.running)
            proc.signal(10); // SIGUSR1
        root.visible = false;
    }

    function toggle(): void {
        if (root.visible)
            hide();
        else
            show();
    }

    Process {
        id: proc

        // wvkbdBelowShell from home/caelestia.nix, on PATH via home.packages.
        //
        // -L is the height that applies here: wvkbd picks its landscape
        // height whenever the output is wider than it is tall, and its
        // default is 120 px (four rows of 30 px, 2026-09-16). -H only covers a
        // rotated/portrait output, kept equal so the size never changes with
        // orientation. Font scaled with the rows.
        //
        // WVKBD_WIDTH is not upstream: the wvkbd override in home/caelestia.nix
        // adds it. Set, the surface is anchored to the bottom edge only and
        // asks for this width, so layer-shell centres it. Unset or 0 gives
        // upstream's full-width keyboard back.
        //
        // --non-exclusive: no exclusive zone, so the keyboard floats over the
        // windows instead of shrinking the tiled area while it is up.
        command: ["wvkbd-mobintl", "-L", "250", "-H", "250", "--fn", "Rubik 20", "--non-exclusive"]
        environment: ({
                WVKBD_WIDTH: "1000"
            })
        onExited: { // qmllint disable signal-handler-parameters
            root.visible = false;
        }
    }

    Process {
        command: ["pkill", "-x", "wvkbd-mobintl"]
        running: true
    }

    IpcHandler {
        target: "osk"

        function toggle(): void {
            root.toggle();
        }

        function show(): void {
            root.show();
        }

        function hide(): void {
            root.hide();
        }

        function isVisible(): bool {
            return root.visible;
        }
    }
}
