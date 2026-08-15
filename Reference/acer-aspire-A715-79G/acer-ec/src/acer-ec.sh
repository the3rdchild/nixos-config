#!/bin/bash
set -euo pipefail

SYS=/sys/kernel/acer_fanctl
LED=/sys/class/leds/acer_ec::kbd_backlight

PROFILE_NAMES=(quiet balanced performance gaming)

err() { echo "$1" >&2; exit 1; }

# Writes go straight to sysfs when the group permissions allow it (see the
# tmpfiles/udev rules); only fall back to sudo when they don't.
write_or_root() {
    local val=$1 path=$2; shift 2
    if ! echo "$val" > "$path" 2>/dev/null; then
        [ "$(id -u)" -eq 0 ] && err "cannot write $path"
        exec sudo "$0" "$@"
    fi
}

prof_num() {
    case "$1" in
        1|quiet)       echo 1 ;;
        2|balanced)    echo 2 ;;
        3|performance) echo 3 ;;
        4|gaming)      echo 4 ;;
        *) err "Invalid profile. Use 1-4 or: quiet balanced performance gaming" ;;
    esac
}

cmd_status() {
    cat "$SYS/all"
}

cmd_status_json() {
    local p rpm1 rpm2 tmp d1 d2 kbd
    p=$(cat "$SYS/profile")
    rpm1=$(cat "$SYS/fan1_rpm"); rpm2=$(cat "$SYS/fan2_rpm")
    d1=$(cat "$SYS/fan1_duty");  d2=$(cat "$SYS/fan2_duty")
    tmp=$(cat "$SYS/tmp_temp")
    kbd=$([ -e "$LED/brightness" ] && cat "$LED/brightness" || echo -1)
    printf '{"profile":%s,"profile_name":"%s","cpu_rpm":%s,"gpu_rpm":%s,' \
        "$p" "${PROFILE_NAMES[$p-1]}" "$rpm1" "$rpm2"
    printf '"cpu_duty":%s,"gpu_duty":%s,"temp":%s,"kbd":%s}\n' \
        "$d1" "$d2" "$tmp" "$kbd"
}

# Waybar custom-module payloads. "class" drives the CSS colour.
cmd_waybar_fan() {
    local p tmp rpm1 rpm2 icon
    p=$(cat "$SYS/profile")
    tmp=$(cat "$SYS/tmp_temp")
    rpm1=$(cat "$SYS/fan1_rpm"); rpm2=$(cat "$SYS/fan2_rpm")
    case "$p" in
        1) icon="󰢙" ;;   # quiet
        2) icon="󰈐" ;;   # balanced
        3) icon="󰈐" ;;   # performance
        4) icon="󰓅" ;;   # gaming
    esac
    printf '{"text":"%s %s°C","tooltip":"Profile: %s\\nCPU fan: %s RPM\\nGPU fan: %s RPM\\nEC temp: %s°C\\n\\nClick to cycle profile","class":"%s"}\n' \
        "$icon" "$tmp" "${PROFILE_NAMES[$p-1]}" "$rpm1" "$rpm2" "$tmp" "${PROFILE_NAMES[$p-1]}"
}

cmd_waybar_kbd() {
    local cur max pct icon cls
    if [ ! -e "$LED/brightness" ]; then
        printf '{"text":"","tooltip":"keyboard backlight unavailable"}\n'
        return
    fi
    cur=$(cat "$LED/brightness"); max=$(cat "$LED/max_brightness")
    pct=$(( cur * 100 / max ))
    if [ "$cur" -eq 0 ]; then icon="󰌌"; cls="off"; else icon="󰥻"; cls="on"; fi
    printf '{"text":"%s %s%%","tooltip":"Keyboard backlight: %s%%\\n\\nClick to toggle, scroll to adjust","class":"%s","percentage":%s}\n' \
        "$icon" "$pct" "$pct" "$cls" "$pct"
}

cmd_profile() {
    if [ -z "${1:-}" ]; then
        local p; p=$(cat "$SYS/profile")
        echo "${PROFILE_NAMES[$p-1]} ($p)"
        return
    fi
    local val; val=$(prof_num "$1")
    write_or_root "$val" "$SYS/profile" profile "$1"
    echo "Profile set to ${PROFILE_NAMES[$val-1]} ($val)"
}

cmd_profile_cycle() {
    local p; p=$(cat "$SYS/profile")
    p=$(( p % 4 + 1 ))
    write_or_root "$p" "$SYS/profile" profile "$p"
    echo "${PROFILE_NAMES[$p-1]} ($p)"
}

cmd_kbd() {
    [ -e "$LED/brightness" ] || err "keyboard backlight not available (acer_ec_kbd loaded?)"
    if [ -z "${1:-}" ]; then
        cat "$LED/brightness"
        return
    fi
    local cur max val
    cur=$(cat "$LED/brightness")
    max=$(cat "$LED/max_brightness")
    case "$1" in
        toggle) if [ "$cur" -gt 0 ]; then val=0; else val=$max; fi ;;
        up)     val=$(( cur + 51 )); [ "$val" -gt "$max" ] && val=$max ;;
        down)   val=$(( cur - 51 )); [ "$val" -lt 0 ] && val=0 ;;
        *[!0-9]*) err "Usage: acer-ec kbd [toggle|up|down|0-$max]" ;;
        *)      val=$1; [ "$val" -gt "$max" ] && val=$max ;;
    esac
    write_or_root "$val" "$LED/brightness" kbd "$val"
    echo "$val"
}

case "${1:-status}" in
    status|st)
        if [ "${2:-}" = "--json" ]; then cmd_status_json; else cmd_status; fi
        ;;
    json)          cmd_status_json ;;
    waybar)        cmd_waybar_fan ;;
    waybar-kbd)    cmd_waybar_kbd ;;
    profile)       cmd_profile "${2:-}" ;;
    profile-cycle) cmd_profile_cycle ;;
    kbd)           cmd_kbd "${2:-}" ;;
    help|--help|-h)
        cat <<'EOF'
Usage: acer-ec [command]

  acer-ec                    Show status (default)
  acer-ec status             Show fan/temp values
  acer-ec status --json      Machine-readable status (for panels/widgets)
  acer-ec profile            Show current profile
  acer-ec profile gaming     Set profile (1-4 or quiet/balanced/performance/gaming)
  acer-ec profile-cycle      Advance to the next profile
  acer-ec kbd                Show keyboard backlight level
  acer-ec kbd toggle         Toggle keyboard backlight
  acer-ec kbd up|down        Step keyboard backlight
  acer-ec kbd 128            Set keyboard backlight (0-255)
  acer-ec waybar             Waybar JSON for the fan/profile module
  acer-ec waybar-kbd         Waybar JSON for the keyboard backlight module
  acer-ec help               This message
EOF
        ;;
    *)
        err "Unknown command: $1. Use: status, json, profile, profile-cycle, kbd, help"
        ;;
esac
