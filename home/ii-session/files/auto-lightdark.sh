export PATH=@path@
flag="${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse/auto-lightdark"

# Upstream's rule as the fallback, but read through dconf rather than
# gsettings. ../home/qt.nix documents why: glib.bin's gsettings only
# reaches the real database when GIO_EXTRA_MODULES points at dconf's GIO
# module, and without it every read silently returns the SCHEMA DEFAULT —
# 'default' for color-scheme, which this function would then report as
# light. A wrong answer that looks like a working read is the worst kind
# for something that runs unattended on every wallpaper change.
from_dconf() {
  case "$(@dconf@/bin/dconf read /org/gnome/desktop/interface/color-scheme 2>/dev/null | tr -d "'")" in
    prefer-dark) echo dark ;;
    *)           echo light ;;
  esac
}

# Missing flag file means on.
# $2 is whatever --mode the caller asked for, empty if none. With auto off
# it passes straight through, so upstream's own precedence is untouched:
# an explicit mode wins, and with neither it falls back to dconf below.
explicit="${2:-}"
passthrough() { [ -n "$explicit" ] && echo "$explicit" || from_dconf; }

[ "$(cat "$flag" 2>/dev/null)" = "0" ] && { passthrough; exit 0; }

# Auto on outranks the explicit mode — the Settings light/dark buttons
# stop having an effect until `ii-lightdark-auto off`. That is the asked-for
# behaviour: one switch decides, rather than two that quietly fight.
img="$1"

# Not every caller passes an image. switchwall.sh regenerates colours from
# several paths — a bare run, --noswitch, the shell re-applying after a
# restart — and with no image to measure this used to fall through to
# dconf, which re-applied whatever mode was already set. The effect was a
# mode that latched: change the wallpaper to a dark one, have anything
# regenerate colours without naming it, and the old light mode came back
# and stayed. So fall back to the wallpaper the shell actually has
# configured before falling back to the previous mode.
if [ -z "$img" ] || [ ! -f "$img" ]; then
  cfg="${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse/config.json"
  img="$(@jq@/bin/jq -r '.background.wallpaperPath // empty' "$cfg" 2>/dev/null)"
fi
[ -n "$img" ] && [ -f "$img" ] || { passthrough; exit 0; }
# A video is measured by its still frame, the same one its palette comes
# from (see videoFrame).
case "${img,,}" in
  *.mp4|*.webm|*.mkv|*.avi|*.mov)
    img="$(@videoFrame@ "$img")" || { passthrough; exit 0; } ;;
esac

# Mean of the image collapsed to one grey pixel: 0 is black, 1 is white.
mean="$(magick "$img" -colorspace Gray -resize 1x1! -format '%[fx:mean]' info: 2>/dev/null)"
[ -n "$mean" ] || { passthrough; exit 0; }
# Below the threshold is dark, at or above it is light.
awk -v m="$mean" -v t="@threshold@" 'BEGIN { print (m >= t) ? "light" : "dark" }'
