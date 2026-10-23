thumbnail="$(@videoFrame@ "$imgpath")"

if [[ -z "$colors_only_flag" ]]; then
    local video_path="$imgpath"
    local play_path
    play_path="$(@videoProxy@/bin/ii-video-proxy "$imgpath")" || play_path="$imgpath"
    monitors=$(hyprctl monitors -j | jq -r '.[] | .name')
    rm -f "$MPV_SOCKET_PREFIX"*.sock
    for monitor in $monitors; do
        mpvpaper $MPVPAPER_FLAGS -o "$VIDEO_OPTS input-ipc-server=$MPV_SOCKET_PREFIX$monitor.sock" "$monitor" "$play_path" &
        sleep 0.1
    done
    @blurCacheOff@

    set_thumbnail_path "$thumbnail"
    set_wallpaper_path "$imgpath"
fi
