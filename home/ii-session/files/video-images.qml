readonly property list<string> validVideoExtensions: ["mp4", "webm", "mkv", "avi", "mov"]

function isVideoByName(name: string): bool {
    const lower = (name || "").toLowerCase();
    return validVideoExtensions.some(t => lower.endsWith("." + t));
}

// Where ii-video-frame (NixOS config) puts a video's still frame.
function videoFramePath(path: string): string {
    const name = (path || "").split("/").pop();
    return Directories.config.replace(/^file:\/\//, "") + "/hypr/custom/scripts/mpvpaper_thumbnails/" + name + ".jpg";
}
