if [[ -z "$colors_only_flag" ]]; then
    set_wallpaper_path "$imgpath"

    local video_path="$imgpath"
    monitors=$(hyprctl monitors -j | jq -r '.[] | .name')
    rm -f "$MPV_SOCKET_PREFIX"*.sock
    for monitor in $monitors; do
        mpvpaper $MPVPAPER_FLAGS -o "$VIDEO_OPTS input-ipc-server=$MPV_SOCKET_PREFIX$monitor.sock" "$monitor" "$video_path" &
        sleep 0.1
    done
fi

thumbnail="$THUMBNAIL_DIR/$(basename "$imgpath").jpg"
ffmpeg -y -i "$imgpath" -vframes 1 "$thumbnail" 2>/dev/null

if [[ -z "$colors_only_flag" ]]; then
    set_thumbnail_path "$thumbnail"
fi
