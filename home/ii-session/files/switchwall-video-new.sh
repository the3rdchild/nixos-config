thumbnail="$(@videoFrame@ "$imgpath")"

if [[ -z "$colors_only_flag" ]]; then
    local video_path="$imgpath"
    local play_path
    play_path="$(@videoProxy@/bin/ii-video-proxy "$imgpath")" || play_path="$imgpath"
    monitors=$(hyprctl monitors -j | jq -r '.[] | .name')
    for monitor in $monitors; do
        mpvpaper -o "$VIDEO_OPTS input-ipc-server=$XDG_RUNTIME_DIR/mpvpaper-$monitor.sock" "$monitor" "$play_path" &
        sleep 0.1
    done
    @blurCacheOff@

    set_thumbnail_path "$thumbnail"
    set_wallpaper_path "$imgpath"
fi
