export PATH=@path@
src="$1"
dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/custom/scripts/mpvpaper_thumbnails"
frame="$dir/$(basename "$src").jpg"
if [ ! -s "$frame" ] || [ "$src" -nt "$frame" ]; then
  mkdir -p "$dir"
  tmp="$frame.$$.jpg"
  if ! ffmpeg -nostdin -v error -y -i "$src" -frames:v 1 -q:v 2 "$tmp"; then
    rm -f "$tmp"
    exit 1
  fi
  mv -f "$tmp" "$frame"
fi
echo "$frame"
