
// Wallpaper-adaptive islands (NixOS config, ii-session.nix): in the island
// style the background is the wallpaper behind it, sampled at three points
// along the group, tinted into the theme and kept readable. See
// WallpaperRegions.
readonly property bool islandAdaptive: Config.options.bar.cornerStyle === 2
    && root.paintBackground
    && Config.options?.bar.borderless !== "transparent"
    && WallpaperRegions.ready
// Where the island sits on its screen. Summed up the parent chain rather
// than mapToItem() so the binding follows every x/y above it: a row
// reflowing, the bar sliding in, the bar moving to another edge.
readonly property rect islandScreenRect: {
    const win = root.QsWindow.window;
    if (!root.islandAdaptive || !win || !win.screen)
        return Qt.rect(0, 0, 0, 0);
    let x = 0, y = 0;
    for (let item = islandBackground; item; item = item.parent) {
        x += item.x;
        y += item.y;
    }
    const sw = win.screen.width, sh = win.screen.height;
    const edges = win.anchors, margins = win.margins;
    const wx = !edges || edges.left ? (margins?.left ?? 0)
        : edges.right ? sw - win.width - (margins?.right ?? 0) : (sw - win.width) / 2;
    const wy = !edges || edges.top ? (margins?.top ?? 0)
        : edges.bottom ? sh - win.height - (margins?.bottom ?? 0) : (sh - win.height) / 2;
    return Qt.rect(wx + x, wy + y, islandBackground.width, islandBackground.height);
}
readonly property var islandStops: {
    const r = root.islandScreenRect;
    const screen = root.QsWindow.window?.screen;
    if (!root.islandAdaptive || !screen || r.width <= 0 || r.height <= 0 || WallpaperRegions.cells.length === 0)
        return [];
    const base = Appearance.colors.colLayer0Base;
    const foreground = Appearance.colors.colOnLayer0;
    const stops = [];
    for (let i = 0; i < 3; i++) {
        const part = root.vertical
            ? Qt.rect(r.x, r.y + r.height * i / 3, r.width, r.height / 3)
            : Qt.rect(r.x + r.width * i / 3, r.y, r.width / 3, r.height);
        stops.push(WallpaperRegions.islandColor(
            WallpaperRegions.regionColor(part, screen.width, screen.height),
            base, foreground, 0.5, 0.65, 4.5));
    }
    return stops;
}
readonly property bool islandPainted: root.islandStops.length === 3
