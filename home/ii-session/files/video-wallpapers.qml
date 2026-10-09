property string configuredWallpaperPath: Config.options.background.wallpaperPath
onConfiguredWallpaperPathChanged: root.confirmedPath = ""

function requestThumbnails(size: string) {
    if (thumbgenProc.running)
        return;
    root.generateThumbnail(size);
}
