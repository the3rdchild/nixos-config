export PATH=@path@
cached=
if [ "${1:-}" = --cached ]; then cached=1; shift; fi
src="${1:-}"
[ -f "$src" ] || { echo "usage: ii-video-proxy [--cached] <video>  (prints the file to play)" >&2; exit 2; }
real="$(realpath "$src")"

IFS=, read -r w h rate < <(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,avg_frame_rate -of csv=p=0 "$real")
if [ -z "$w" ] || [ -z "$h" ]; then echo "$src"; exit 0; fi

read -r tw th shrink slow < <(awk -v w="$w" -v h="$h" -v r="$rate" 'BEGIN {
  s = 1920 / w; if (1080 / h > s) s = 1080 / h; if (s > 1) s = 1
  n = split(r, f, "/"); fps = (n == 2 && f[2] > 0) ? f[1] / f[2] : f[1] + 0
  printf "%d %d %d %d\n", int(w * s / 2 + 0.5) * 2, int(h * s / 2 + 0.5) * 2, (s < 0.99), (fps > 30.5)
}')
if [ "$shrink" = 0 ] && [ "$slow" = 0 ]; then echo "$src"; exit 0; fi

dir="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/wallpaper-proxies"
key="$(printf '%s %s' "$real" "$(stat -c '%s %Y' "$real")" | sha1sum | cut -c1-12)"
base="$(basename "$real")"
out="$dir/${base%.*}.$key.mp4"
if [ -s "$out" ]; then echo "$out"; exit 0; fi
[ -z "$cached" ] || exit 1

mkdir -p "$dir"
exec 9>"$out.lock"
flock 9
if [ -s "$out" ]; then echo "$out"; exit 0; fi
notify-send -a "Wallpaper switcher" "Optimizing video wallpaper" \
  "$base: ${w}x${h} to ${tw}x${th}, at most 30fps. This happens once; it starts playing when done." || true
tmp="$out.$$.mp4"
hwvf="scale_vaapi=w=$tw:h=$th:format=nv12"
swvf="scale=$tw:$th:flags=lanczos"
if [ "$slow" = 1 ]; then hwvf="fps=30,$hwvf"; swvf="fps=30,$swvf"; fi
if ffmpeg -nostdin -v error -y -hwaccel vaapi -hwaccel_output_format vaapi -i "$real" \
     -an -vf "$hwvf" -c:v h264_vaapi -qp 20 "$tmp" \
  || ffmpeg -nostdin -v error -y -i "$real" \
     -an -vf "$swvf" -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p "$tmp"; then
  mv -f "$tmp" "$out"
  echo "$out"
else
  rm -f "$tmp"
  notify-send -a "Wallpaper switcher" -u critical "Could not optimize video wallpaper" \
    "$base plays as it is." || true
  echo "$src"
fi
