export PATH=@path@
cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse"
flag="$cfgdir/auto-lightdark"
state() { [ "$(cat "$flag" 2>/dev/null)" = "0" ] && echo off || echo on; }

case "${1:-status}" in
  status) echo "auto light/dark: $(state)" ;;
  on|off)
    mkdir -p "$cfgdir"
    [ "$1" = "on" ] && echo 1 > "$flag" || echo 0 > "$flag"
    echo "auto light/dark: $(state)"
    # Re-derive straight away for the wallpaper that is already set.
    if [ "$1" = "on" ]; then
      wp="$(jq -r '.background.wallpaperPath // empty' "$cfgdir/config.json" 2>/dev/null)"
      [ -n "$wp" ] && exec "${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/@qsConfig@/scripts/colors/switchwall.sh" --noswitch --image "$wp"
    fi
    ;;
  toggle) [ "$(state)" = "on" ] && exec "$0" off || exec "$0" on ;;
  *) echo "usage: ii-lightdark-auto [status|on|off|toggle]" >&2; exit 2 ;;
esac
