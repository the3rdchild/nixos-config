export PATH=@path@:$PATH

sock="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

# Outputs Hyprland is actually advertising to Wayland clients (wl_output).
advertised() {
  wayland-info -i wl_output 2>/dev/null | sed -n 's/^[[:space:]]*name: //p' | sort -u
}

# Outputs Hyprland itself considers live: enabled and not mirroring another
# one. A mirroring output is left out because it is not expected to get its own
# wl_output, and healing it would only break the mirror.
live() {
  hyprctl monitors -j | jq -r '.[] | select((.disabled | not) and ((.mirrorOf // "none") == "none")) | .name' | sort -u
}

heal() {
  local missing m
  missing=$(comm -23 <(live) <(advertised))
  [ -n "$missing" ] || return 0
  for m in $missing; do
    notify-send -a ii-output-heal -t 4000 "Display $m" "Not visible to the shell, re-initialising it" 2>/dev/null || true
    hyprctl eval "hl.monitor({ output = \"$m\", disabled = true })" >/dev/null
  done
  sleep 1
  # Reload re-applies monitors.lua, which is what brings the output back
  # with its configured mode, position and scale.
  hyprctl reload >/dev/null
}

# Debounced: a mirror toggle is a burst of events (nwg-displays writes the
# file, reloads, the output comes and goes), and the stale state only exists
# once the burst has settled.
socat -u "UNIX-CONNECT:$sock" - | while read -r ev; do
  case $ev in
    configreloaded\>\>*|monitoraddedv2\>\>*|monitorremoved\>\>*) ;;
    *) continue ;;
  esac
  while read -r -t 3 _; do :; done
  heal
  # The heal's own reload emits events; swallow them so one pass is one pass.
  while read -r -t 4 _; do :; done
done
