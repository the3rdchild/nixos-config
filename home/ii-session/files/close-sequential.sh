export PATH=@path@
mode=$1 token=$2
[ -n "$token" ] || exit 1
dir="${XDG_RUNTIME_DIR:-/tmp}/ii-close-sequential"
mkdir -p "$dir"
stopf="$dir/stop-$token"
if [ "$mode" = stop ]; then touch "$stopf"; exit 0; fi

find "$dir" -name 'stop-*' -mmin +1 -delete 2>/dev/null
exec 9>"$dir/lock"
flock -n 9 || exit 0

stopped() { [ -e "$stopf" ]; }
# Sleep $1 ms in 50ms slices; fails as soon as the keys are released.
nap() {
  local n=$(( $1 / 50 ))
  while [ "$n" -gt 0 ]; do
    stopped && return 1
    sleep 0.05
    n=$(( n - 1 ))
  done
  ! stopped
}
alive() { hyprctl clients -j | jq -e --arg a "$1" 'any(.[]; .address == $a)' >/dev/null; }

# Counted as "windows from the starting set that are gone", so a
# force-kill that takes several windows of one process with it (every
# VS Code window shares a pid) is counted right.
before=$(hyprctl clients -j | jq -c '[.[].address]')
finish() {
  rm -f "$stopf"
  n=$(hyprctl clients -j | jq --argjson s "$before" '$s - [.[].address] | length')
  [ "${n:-0}" -gt 0 ] || exit 0
  if stopped; then body="Stopped on release"; else body="All workspaces done"; fi
  notify-send "Closed $n windows" "$body" -a Hyprland -i window-close
}
trap finish EXIT

nap 300 || exit 0

cur=$(hyprctl activeworkspace -j | jq '.id')
mapfile -t order < <(hyprctl workspaces -j | jq -r --argjson cur "$cur" '
  [.[] | select(.windows > 0)] as $ws
  | ($ws | map(select(.id == $cur)))
    + ($ws | map(select(.id > 0 and .id != $cur)) | sort_by(.id))
    + ($ws | map(select(.id < 0)) | sort_by(.name))
  | .[] | "\(.id) \(.name)"')

for entry in "${order[@]}"; do
  id=${entry%% *} name=${entry#* }
  if [ "$id" -lt 0 ]; then
    # toggle_special hides it again if it is already open somewhere.
    hyprctl monitors -j | jq -e --arg n "$name" 'any(.[]; .specialWorkspace.name == $n)' >/dev/null ||
      hyprctl dispatch "hl.dsp.workspace.toggle_special(\"${name#special:}\")" >/dev/null
    nap 400 || exit 0
  elif [ "$id" != "$(hyprctl activeworkspace -j | jq '.id')" ]; then
    hyprctl dispatch "hl.dsp.focus({ workspace = $id })" >/dev/null
    nap 400 || exit 0
  fi

  # Most recently focused first, i.e. the window actually on top. The
  # cap only guards against something that respawns its window forever.
  for _ in $(seq 1 64); do
    read -r addr pid < <(hyprctl clients -j | jq -r --argjson id "$id" '
      [.[] | select(.workspace.id == $id)] | sort_by(.focusHistoryID) | first
      | select(. != null) | "\(.address) \(.pid)"')
    [ -n "$addr" ] || break

    hyprctl dispatch "hl.dsp.window.close({ window = \"address:$addr\" })" >/dev/null
    for _ in $(seq 1 15); do
      alive "$addr" || break
      nap 100 || exit 0
    done
    if alive "$addr"; then
      hyprctl dispatch "hl.dsp.window.kill({ window = \"address:$addr\" })" >/dev/null
      nap 500 || exit 0
      if alive "$addr" && [ "${pid:-0}" -gt 1 ]; then kill -9 "$pid" 2>/dev/null; fi
    fi
    addr=""
    nap 250 || exit 0
  done
done
