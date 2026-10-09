readonly property bool isVideo: Images.isVideoByName(sourcePath)
property bool videoThumbnailRequested: false
onStatusChanged: {
    if (status !== Image.Error || !isVideo || videoThumbnailRequested)
        return;
    videoThumbnailRequested = true;
    Wallpapers.requestThumbnails(thumbnailSizeName);
}

Rectangle {
    visible: thumbnailImage.isVideo
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: 6
    width: videoBadgeIcon.implicitWidth + 8
    height: width
    radius: width / 2
    color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.3)

    MaterialSymbol {
        id: videoBadgeIcon
        anchors.centerIn: parent
        text: "play_arrow"
        iconSize: Appearance.font.pixelSize.normal
        fill: 1
        color: Appearance.colors.colOnLayer0
    }
}
