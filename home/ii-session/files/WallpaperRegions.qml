pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common

// The wallpaper as a coarse colour grid, so the bar's islands can take on
// the colour of what is behind them (NixOS config, ii-session.nix).
Singleton {
    id: root

    readonly property int gridWidth: 96
    readonly property int gridHeight: 54

    // Always a still: a video contributes its frame, as Background.qml does.
    readonly property string source: {
        const path = Config.options.background.wallpaperPath || "";
        return Images.isVideoByName(path) ? Images.videoFramePath(path) : path;
    }

    property bool ready: false
    property real imageAspect: 16 / 9
    property var cells: [] // row-major r, g, b in 0..1
    property string loadingSource: ""
    property bool pending: false
    property int attempts: 0

    onSourceChanged: {
        root.attempts = 0;
        root.load();
    }
    Component.onCompleted: root.load()

    function load() {
        if (!root.source) {
            root.ready = false;
            return;
        }
        if (grid.running) {
            root.pending = true;
            return;
        }
        root.loadingSource = root.source;
        grid.exec(["@barRegionsGrid@", root.source, root.gridWidth + "x" + root.gridHeight]);
    }

    // First line "width height" of the original, then a plain PPM.
    function parse(text) {
        if (root.loadingSource !== root.source)
            return; // superseded; pending reloads it
        const lines = text.split("\n").filter(line => !line.startsWith("#"));
        const size = (lines.shift() || "").trim().split(/\s+/).map(Number);
        const tokens = lines.join(" ").trim().split(/\s+/);
        const count = root.gridWidth * root.gridHeight * 3;
        const valid = size.length === 2 && size[0] > 0 && size[1] > 0
            && tokens[0] === "P3"
            && Number(tokens[1]) === root.gridWidth
            && Number(tokens[2]) === root.gridHeight
            && tokens.length >= 4 + count;
        if (!valid) {
            // A new video's frame can land a moment after the config does.
            if (++root.attempts <= 10)
                retry.restart();
            else
                root.ready = false;
            return;
        }
        const max = Number(tokens[3]) || 255;
        const cells = new Array(count);
        for (let i = 0; i < count; i++)
            cells[i] = Number(tokens[4 + i]) / max;
        root.imageAspect = size[0] / size[1];
        root.cells = cells;
        root.ready = true;
    }

    // Mean colour of a rectangle of a screen, in that screen's logical
    // pixels, with the wallpaper laid out as Background.qml and mpvpaper
    // (panscan=1.0) lay it out: scaled to cover, centred, cropped.
    function regionColor(rect, screenWidth, screenHeight) {
        const cells = root.cells;
        if (cells.length < root.gridWidth * root.gridHeight * 3 || screenWidth <= 0 || screenHeight <= 0)
            return Qt.rgba(0, 0, 0, 1);
        let u0 = rect.x / screenWidth, u1 = (rect.x + rect.width) / screenWidth;
        let v0 = rect.y / screenHeight, v1 = (rect.y + rect.height) / screenHeight;
        const screenAspect = screenWidth / screenHeight;
        if (root.imageAspect > screenAspect) {
            const f = screenAspect / root.imageAspect;
            u0 = 0.5 - f / 2 + u0 * f;
            u1 = 0.5 - f / 2 + u1 * f;
        } else {
            const f = root.imageAspect / screenAspect;
            v0 = 0.5 - f / 2 + v0 * f;
            v1 = 0.5 - f / 2 + v1 * f;
        }
        const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
        const x0 = clamp(Math.floor(u0 * root.gridWidth), 0, root.gridWidth - 1);
        const x1 = clamp(Math.ceil(u1 * root.gridWidth) - 1, x0, root.gridWidth - 1);
        const y0 = clamp(Math.floor(v0 * root.gridHeight), 0, root.gridHeight - 1);
        const y1 = clamp(Math.ceil(v1 * root.gridHeight) - 1, y0, root.gridHeight - 1);
        let r = 0, g = 0, b = 0, n = 0;
        for (let y = y0; y <= y1; y++) {
            for (let x = x0; x <= x1; x++) {
                const i = (y * root.gridWidth + x) * 3;
                r += cells[i];
                g += cells[i + 1];
                b += cells[i + 2];
                n++;
            }
        }
        return Qt.rgba(r / n, g / n, b / n, 1);
    }

    function luminance(c) {
        const lin = v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }

    function contrast(a, b) {
        const la = root.luminance(a), lb = root.luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    // a towards b by t
    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
    }

    // An island over `sample`: `tint` of the sample mixed into `base`,
    // at `opacity`, pushed away from `foreground` until the foreground
    // keeps `minContrast` on the composite (island over the wallpaper);
    // then more opaque if that is not enough.
    function islandColor(sample, base, foreground, tint, opacity, minContrast) {
        const tinted = root.mix(base, sample, tint);
        const away = root.luminance(foreground) > root.luminance(base) ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1);
        for (const alpha of [opacity, (opacity + 1) / 2, 1]) {
            for (let step = 0; step <= 10; step++) {
                const c = root.mix(tinted, away, step / 10);
                if (root.contrast(root.mix(sample, c, alpha), foreground) >= minContrast)
                    return Qt.rgba(c.r, c.g, c.b, alpha);
            }
        }
        return Qt.rgba(base.r, base.g, base.b, 1);
    }

    Process {
        id: grid
        stdout: StdioCollector {
            onStreamFinished: root.parse(this.text)
        }
        onRunningChanged: {
            if (!running && root.pending) {
                root.pending = false;
                Qt.callLater(root.load);
            }
        }
    }

    Timer {
        id: retry
        interval: 1000
        onTriggered: root.load()
    }
}
