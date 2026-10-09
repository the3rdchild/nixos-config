export PATH=@path@

on_battery() { [ "$(cat /sys/class/power_supply/AC/online 2>/dev/null)" = 0 ]; }
lid_closed() { grep -qs closed /proc/acpi/button/lid/*/state; }
panel() { hyprctl monitors -j | jq -r 'first(.[] | select(.name | startswith("eDP")) | .name) // empty'; }
dpms() { hyprctl dispatch "hl.dsp.dpms({ action = \"$1\"${2:+, monitor = \"$2\"} })" >/dev/null; }
wake_on_input() {
  hyprctl dispatch "function() hl.config({ misc = { mouse_move_enables_dpms = $1, key_press_enables_dpms = $1 } }) end" >/dev/null
}

case "${1:-}" in
  lid-close)
    wake_on_input false
    p=$(panel)
    if [ -n "$p" ]; then dpms disable "$p"; fi
    ;;
  lid-open)
    wake_on_input true
    p=$(panel)
    if [ -n "$p" ]; then dpms enable "$p"; fi
    ;;
  idle-off)
    if on_battery; then dpms disable; fi
    ;;
  idle-lock)
    if on_battery; then loginctl lock-session; fi
    ;;
  wake)
    # Per monitor, and only the ones that are actually off, so a resume
    # on AC (where idle-off did nothing) touches no screen at all.
    skip=
    if lid_closed; then skip=$(panel); fi
    hyprctl monitors -j | jq -r '.[] | select(.dpmsStatus | not) | .name' |
    while read -r m; do
      if [ "$m" != "$skip" ]; then dpms enable "$m"; fi
    done
    ;;
  *)
    echo "usage: ii-display-power lid-close|lid-open|idle-off|idle-lock|wake" >&2
    exit 2
    ;;
esac
exit 0
