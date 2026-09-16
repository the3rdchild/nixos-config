pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.utils

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

    // ── Colours: follow the shell's scheme, light or dark.
    //
    // wvkbd only takes colours on its command line, so they are built here
    // from the current Material palette (Colours.current, never the nexus
    // preview) and a scheme change restarts a running keyboard, see
    // restartTimer. Surfaces are translucent - 70 % background, 85 % keys -
    // and Hyprland blurs what shows through (layer_rule in home/caelestia.nix).
    // Text stays opaque. Normal keys sit on the highest surface tone, special
    // keys (Shift, arrows, Enter...) on the secondary container, presses on
    // the primary container, the same roles the bar's own buttons use.
    readonly property var p: Colours.current
    readonly property var colourArgs: [
        "--bg", hex(p.m3surfaceContainer, 0.70),
        "--fg", hex(p.m3surfaceContainerHighest, 0.85),
        "--fg-sp", hex(p.m3secondaryContainer, 0.85),
        "--press", hex(p.m3primaryContainer, 1),
        "--press-sp", hex(p.m3primaryContainer, 1),
        "--swipe", hex(p.m3primary, 0.25),
        "--swipe-sp", hex(p.m3primary, 0.25),
        "--text", hex(p.m3onSurface, 1),
        "--text-sp", hex(p.m3onSecondaryContainer, 1)
    ]

    // ── Position: where the last drag of the move key (beside Tab) ended.
    //
    // Fractions of the free space, "x,y": 0,0 top-left, 1,1 bottom-right,
    // default bottom-centre. wvkbd prints `wvkbd-position x,y` when a drag
    // ends (home/caelestia/wvkbd/osk-move.h); it is saved here and handed
    // back in WVKBD_POSITION, so hide/show, scheme restarts and reboots all
    // reopen it in the same place. Fractions rather than pixels, so the
    // other monitor puts it in the same relative spot.
    property string position: "0.5,1"

    FileView {
        id: positionFile

        printErrors: false
        path: `${Paths.state}/osk.json`
        onLoaded: {
            try {
                const data = JSON.parse(text());
                if (/^[0-9.]+,[0-9.]+$/.test(data.position ?? ""))
                    root.position = data.position;
            } catch (e) {}
        }
    }

    // True while a scheme-change restart is in flight, and whether the
    // keyboard was on screen when it began.
    property bool restarting: false
    property bool restartVisible: false

    // wvkbd's "rrggbbaa", no leading '#'.
    function hex(c: color, alpha: real): string {
        const byte = v => Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).padStart(2, "0");
        return byte(c.r) + byte(c.g) + byte(c.b) + byte(alpha);
    }

    // A scheme switch rewrites every palette role at once; the timer folds
    // those into one restart. A hidden keyboard is simply stopped: the next
    // show() starts it with the new colours.
    onColourArgsChanged: restartTimer.restart()

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
        //
        // WVKBD_RADIUS is ours too: rounds all four corners of the panel by
        // clipping wvkbd's drawing buffers (see the same override). 23 px
        // matches Hyprland's window rounding. -R rounds the keys themselves.
        command: ["wvkbd-mobintl", "-L", "200", "-H", "200", "--fn", "Rubik 20", "-R", "8", "--non-exclusive", ...root.colourArgs]
        environment: ({
                WVKBD_WIDTH: "750",
                WVKBD_RADIUS: "23",
                WVKBD_POSITION: root.position
            })
        stdout: SplitParser {
            onRead: data => {
                const m = data.match(/^wvkbd-position ([0-9.]+,[0-9.]+)$/);
                if (!m)
                    return;
                root.position = m[1];
                positionFile.setText(JSON.stringify({
                    position: m[1]
                }) + "\n");
            }
        }
        onExited: { // qmllint disable signal-handler-parameters
            root.visible = false;
            if (root.restarting) {
                root.restarting = false;
                if (root.restartVisible)
                    root.show();
            }
        }
    }

    Timer {
        id: restartTimer

        interval: 300
        onTriggered: {
            if (!proc.running)
                return;
            root.restartVisible = root.visible;
            root.restarting = true;
            proc.running = false;
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
