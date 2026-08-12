#!/bin/bash
set -euo pipefail

SYS=/sys/kernel/acer_fanctl

if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

PROFILE_NAMES=(quiet balanced performance gaming)

err() { echo "$1" >&2; exit 1; }

cmd_status() {
    cat "$SYS/all"
}

cmd_profile_show() {
    echo "Profiles: 1=quiet 2=balanced 3=performance 4=gaming"
    echo "Usage: acer-ec profile <1-4|name>"
}

cmd_profile_set() {
    case "$1" in
        1|quiet)     val=1 ;;
        2|balanced)  val=2 ;;
        3|performance) val=3 ;;
        4|gaming)    val=4 ;;
        *)           err "Invalid profile. Use 1-4 or: quiet balanced performance gaming" ;;
    esac
    echo "$val" > "$SYS"/profile
    echo "Profile set to ${PROFILE_NAMES[$val-1]} ($val)"
}

case "${1:-status}" in
    status|st)
        cmd_status
        ;;
    profile)
        if [ -z "${2:-}" ]; then
            cmd_profile_show
        else
            cmd_profile_set "$2"
        fi
        ;;
    help|--help|-h)
        echo "Usage: acer-ec [command]"
        echo ""
        echo "  acer-ec              Show status (default)"
        echo "  acer-ec status       Show fan/temp values"
        echo "  acer-ec profile      Show profile help"
        echo "  acer-ec profile 4    Set profile by number"
        echo "  acer-ec profile gaming  Set profile by name"
        echo "  acer-ec help         This message"
        ;;
    *)
        err "Unknown command: $1. Use: status, profile, help"
        ;;
esac
