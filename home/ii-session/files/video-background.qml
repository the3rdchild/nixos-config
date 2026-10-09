readonly property bool videoIsLive: bgRoot.wallpaperIsVideo
    && bgRoot.effectiveWallpaperPath === bgRoot.playingPath
onVideoIsLiveChanged: {
    if (!bgRoot.videoIsLive) {
        videoRevealDelay.stop()
        bgRoot.videoRevealed = false
    } else if (!transitionAnim.running && !bgRoot.transitionPending) {
        videoRevealDelay.restart()
    }
}
Timer {
    id: videoRevealDelay
    interval: 500
    onTriggered: bgRoot.videoRevealed = bgRoot.videoIsLive
}

property string configuredThumbnailPath: Config.options.background.thumbnailPath
onConfiguredThumbnailPathChanged: {
    if (!bgRoot.wallpaperIsVideo || wallpaper.status !== Image.Error) return
    wallpaper.source = ""
    wallpaper.source = bgRoot.wallpaperPath
}

// What this monitor's mpvpaper plays and whether it is paused, kept in
// step by ii-mpvpaper-ctl one call at a time.
readonly property string desktopVideo: Images.isVideoByName(Config.options.background.wallpaperPath)
    ? Config.options.background.wallpaperPath : ""
property bool lockVideoFailed: false
readonly property string lockVideo: {
    const lockWall = Config.options.background.lockWall
    if (!GlobalStates.screenLocked || bgRoot.lockVideoFailed || Config.options.lock.blur.enable) return ""
    if (lockWall === "" || lockWall === Config.options.background.wallpaperPath || !Images.isVideoByName(lockWall)) return ""
    return lockWall
}
readonly property string mpvVideo: bgRoot.lockVideo || bgRoot.desktopVideo
readonly property bool monitorDpmsOff: GlobalStates.screenLocked
    && HyprlandData.monitors.find(m => m.name === bgRoot.modelData.name)?.dpmsStatus === false
readonly property bool videoPaused: GlobalStates.screenLocked
    ? (bgRoot.monitorDpmsOff || Config.options.lock.blur.enable || bgRoot.effectiveWallpaperPath !== bgRoot.mpvVideo)
    : (bgRoot.activeWorkspaceWithFullscreen != undefined || bgRoot.overviewBlurActive)
readonly property string mpvState: bgRoot.mpvVideo === "" ? "" : bgRoot.mpvVideo + (bgRoot.videoPaused ? "|pause" : "|play")
onMpvStateChanged: Qt.callLater(bgRoot.syncMpv)

// "none": the applied wallpaper, as switchwall.sh left it. Otherwise
// what ii-mpvpaper-ctl last confirmed, "" while it is switching.
property string mpvOverride: "none"
readonly property string playingPath: bgRoot.mpvOverride === "none" ? bgRoot.desktopVideo : bgRoot.mpvOverride

function syncMpv() {
    if (mpvProc.running) {
        mpvProc.again = true
        return
    }
    const video = bgRoot.mpvVideo
    mpvProc.video = video
    mpvProc.forLock = video !== "" && video === bgRoot.lockVideo
    if (video !== bgRoot.playingPath) bgRoot.mpvOverride = ""
    mpvProc.command = video === ""
        ? ["@mpvpaperCtl@", bgRoot.modelData.name, "stop"]
        : ["@mpvpaperCtl@", bgRoot.modelData.name, bgRoot.videoPaused ? "pause" : "play", video]
            .concat(mpvProc.forLock ? ["lock"] : [])
    mpvProc.running = true
}
Process {
    id: mpvProc
    property string video: ""
    property bool forLock: false
    property bool again: false
    onExited: exitCode => {
        if (!mpvProc.forLock)
            bgRoot.mpvOverride = "none"
        else if (exitCode === 0)
            bgRoot.mpvOverride = mpvProc.video
        else
            bgRoot.lockVideoFailed = true
        if (mpvProc.again) {
            mpvProc.again = false
            Qt.callLater(bgRoot.syncMpv)
        }
    }
}
Connections {
    target: GlobalStates
    function onScreenLockedChanged() {
        if (!GlobalStates.screenLocked) bgRoot.lockVideoFailed = false
    }
}

// Nothing the shell listens to tells it a screen went off, so while
// locked with a video the monitor list is refreshed every 2s instead.
Timer {
    running: GlobalStates.screenLocked && bgRoot.mpvVideo !== ""
    interval: 2000
    repeat: true
    onTriggered: HyprlandData.updateMonitors()
}
