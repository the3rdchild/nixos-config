export PATH=@path@
usage() { echo "usage: ii-mpvpaper-ctl <monitor> pause|play [<video> [lock]] | stop" >&2; exit 2; }
mon="${1:-}"
[ -n "$mon" ] || usage
sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mpvpaper-$mon.sock"

ipc() { socat -t 1 - "UNIX-CONNECT:$sock" 2>/dev/null <<< "$1" | jq -c 'select(has("error"))' 2>/dev/null | head -n 1; }
get() { ipc "$(jq -nc --arg p "$1" '{command: ["get_property", $p]}')" | jq -r 'select(.error == "success" and .data != null) | .data | tostring'; }
alive() { [ -n "$(get pid)" ]; }
wait_alive() {
  for _ in $(seq 30); do
    alive && return 0
    sleep 0.1
  done
  return 1
}

stop() {
  pkill -9 -f "^[^ ]*mpvpaper .*/mpvpaper-$mon\.sock" || true
  rm -f "$sock"
}

case "${2:-}" in
  stop) stop; exit 0 ;;
  pause) value=true ;;
  play)  value=false ;;
  *) usage ;;
esac
video="${3:-}"
lock="${4:-}"

if [ -z "$video" ]; then
  wait_alive || exit 1
  ipc "{\"command\":[\"set_property\",\"pause\",$value]}" >/dev/null
  exit 0
fi

if ! target="$(ii-video-proxy --cached "$video")"; then
  if [ -n "$lock" ]; then
    setsid -f ii-video-proxy "$video" >/dev/null 2>&1 < /dev/null
    exit 3
  fi
  target="$video"
fi

if ! alive; then
  if [ -n "$lock" ]; then
    rm -f "$sock"
    setsid -f mpvpaper -o "@videoOpts@ input-ipc-server=$sock" "$mon" "$target" >/dev/null 2>&1 < /dev/null
    wait_alive || { stop; exit 1; }
  fi
  wait_alive || exit 1
fi
if [ "$(get path)" != "$target" ]; then
  ipc "$(jq -nc --arg p "$target" '{command: ["loadfile", $p, "replace"]}')" >/dev/null
fi
ipc "{\"command\":[\"set_property\",\"pause\",$value]}" >/dev/null

for _ in $(seq 30); do
  if [ "$(get path)" = "$target" ] && [ -n "$(get playback-time)" ]; then exit 0; fi
  sleep 0.1
done
exit 1
