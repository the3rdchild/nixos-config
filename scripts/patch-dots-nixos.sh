#!/usr/bin/env bash
# Post-copy fixups for JaKooLit's Hyprland-Dots on this NixOS machine.
#
# Run once after ./copy.sh, and again after any dots update (their updater
# restores upstream files). Safe to re-run — every change is idempotent.
#
#   ~/.config/hypr must already exist.

set -euo pipefail

HYPR="$HOME/.config/hypr"

if [ ! -d "$HYPR" ]; then
  echo "error: $HYPR does not exist — run Hyprland-Dots/copy.sh first." >&2
  exit 1
fi

changed=0

# ── swww-daemon --format xrgb  ->  --format argb
#
# nixpkgs' swww is now 'awww' 0.12.x, whose --format only accepts
# argb|abgr|rgb|bgr. The old xrgb/xbgr names were dropped, so the daemon
# would refuse to start and leave you with no wallpaper at all.
mapfile -t hits < <(grep -rlE -- '--format[[:space:]]+x(rgb|bgr)' "$HYPR" 2>/dev/null || true)
if [ ${#hits[@]} -gt 0 ]; then
  for f in "${hits[@]}"; do
    sed -i -E 's/(--format[[:space:]]+)xrgb/\1argb/g; s/(--format[[:space:]]+)xbgr/\1abgr/g' "$f"
    echo "  patched --format: ${f#"$HYPR"/}"
    changed=$((changed + 1))
  done
else
  echo "  --format already argb/abgr — nothing to do"
fi

# ── Hyprland 0.56 API changes
#
# The dots (v2.3.20, Jan 2026) target ~0.53. Verified against the running
# 0.56.0 with `hyprctl descriptions` / `hyprctl dispatch`:
#
#   togglesplit        standalone dispatcher gone -> `layoutmsg, togglesplit`
#   dwindle:pseudotile option removed outright; pseudotiling is dispatcher-only
#                      now, and the dots already bind `pseudo` to $mainMod+P
#   misc:vfr           moved to debug:vfr, which already defaults to 1
#
# `togglesplit` -> `layoutmsg,togglesplit` (no space: ChangeLayout.sh passes
# this through `hyprctl keyword bind` as a shell word).
while IFS= read -r f; do
  grep -qE 'layoutmsg[[:space:]]*,[[:space:]]*togglesplit' "$f" && continue
  sed -i -E 's/([,[:space:]])togglesplit\b/\1layoutmsg,togglesplit/g' "$f"
  echo "  fixed togglesplit dispatcher: ${f#"$HYPR"/}"
  changed=$((changed + 1))
done < <(grep -rlw 'togglesplit' "$HYPR" 2>/dev/null || true)

# Comment out the two options 0.56 no longer knows. Both are no-ops rather
# than behaviour changes: `pseudo` stays bound, and debug:vfr already
# defaults to the value the dots were asking for.
SYSSET="$HYPR/configs/SystemSettings.conf"
if [ -f "$SYSSET" ]; then
  if grep -qE '^[[:space:]]*pseudotile[[:space:]]*=' "$SYSSET"; then
    sed -i -E 's|^([[:space:]]*)(pseudotile[[:space:]]*=.*)$|\1# \2  # removed in Hyprland 0.56 (use the pseudo dispatcher)|' "$SYSSET"
    echo "  commented out dwindle:pseudotile"
    changed=$((changed + 1))
  fi
  if grep -qE '^[[:space:]]*vfr[[:space:]]*=' "$SYSSET"; then
    sed -i -E 's|^([[:space:]]*)(vfr[[:space:]]*=.*)$|\1# \2  # moved to debug:vfr in 0.56, already defaults on|' "$SYSSET"
    echo "  commented out misc:vfr"
    changed=$((changed + 1))
  fi
fi

# ── HyprMod hook
#
# HyprMod writes its GUI settings to ~/.config/hypr/hyprland-gui.conf and,
# on first run, appends `source = ...` to the entrypoint — hyprland.conf,
# which the dots overwrite on every update, silently unhooking the GUI.
#
# Its needs_setup() resolves the whole source chain recursively, not just
# the entrypoint, so putting the line in UserConfigs/UserSettings.conf (which
# the dots preserve across updates) is detected as "already set up" and
# HyprMod leaves hyprland.conf alone permanently.
GUI_CONF="$HYPR/hyprland-gui.conf"
USER_SETTINGS="$HYPR/UserConfigs/UserSettings.conf"

touch "$GUI_CONF"

if [ -f "$USER_SETTINGS" ]; then
  if grep -qF 'hyprland-gui.conf' "$USER_SETTINGS"; then
    echo "  HyprMod hook already present in UserConfigs/UserSettings.conf"
  else
    printf '\n# HyprMod managed settings (see scripts/patch-dots-nixos.sh)\nsource = %s\n' \
      "$GUI_CONF" >>"$USER_SETTINGS"
    echo "  added HyprMod hook to UserConfigs/UserSettings.conf"
    changed=$((changed + 1))
  fi
else
  echo "  warning: $USER_SETTINGS missing — skipped HyprMod hook" >&2
fi

# ── acer-ec waybar widgets
#
# These used to live in home/waybar.nix, which home-manager no longer
# manages. waybar/UserModules is included by every one of the dots' bar
# configs and is explicitly restored by copy.sh, so the definitions survive
# dot updates; the modules-right injection below does not, hence re-running.
WAYBAR="$HOME/.config/waybar"
USER_MODULES="$WAYBAR/UserModules"

if [ -f "$USER_MODULES" ]; then
  if grep -qF 'custom/fan' "$USER_MODULES"; then
    echo "  acer-ec modules already defined in waybar/UserModules"
  else
    # awk, not sed: the module names contain '/', which collides with the
    # s/// delimiter.
    block='"custom/fan": {\n\t"exec": "acer-ec waybar",\n\t"return-type": "json",\n\t"interval": 3,\n\t"on-click": "acer-ec profile-cycle"\n},\n\n"custom/kbd": {\n\t"exec": "acer-ec waybar-kbd",\n\t"return-type": "json",\n\t"interval": 3,\n\t"on-click": "acer-ec kbd toggle",\n\t"on-scroll-up": "acer-ec kbd up",\n\t"on-scroll-down": "acer-ec kbd down"\n}'
    # Insert just inside the opening brace of the (otherwise empty) object.
    awk -v blk="$block" '
      !done && /^[[:space:]]*\{/ { print; print blk; done = 1; next }
      { print }
    ' "$USER_MODULES" >"$USER_MODULES.tmp" && mv "$USER_MODULES.tmp" "$USER_MODULES"
    echo "  defined custom/fan + custom/kbd in waybar/UserModules"
    changed=$((changed + 1))
  fi
else
  echo "  warning: $USER_MODULES missing — skipped acer-ec waybar modules" >&2
fi

# Reference them from every bar config that has a modules-right array.
if [ -d "$WAYBAR/configs" ]; then
  injected=0
  while IFS= read -r -d '' cfg; do
    grep -qF 'custom/fan' "$cfg" && continue
    grep -qE '"modules-right"[[:space:]]*:[[:space:]]*\[' "$cfg" || continue
    # awk again — sed's `a\` mangles the leading tab into a literal \t,
    # which is invalid JSON and stops waybar from starting.
    awk '
      !done && /"modules-right"[[:space:]]*:[[:space:]]*\[/ {
        print
        print "\t\"custom/fan\","
        print "\t\"custom/kbd\","
        done = 1
        next
      }
      { print }
    ' "$cfg" >"$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    injected=$((injected + 1))
  done < <(find "$WAYBAR/configs" -maxdepth 1 -type f -print0)

  if [ "$injected" -gt 0 ]; then
    echo "  injected acer-ec widgets into $injected bar config(s)"
    changed=$((changed + 1))
  else
    echo "  bar configs already reference acer-ec widgets"
  fi
fi

echo
if [ "$changed" -gt 0 ]; then
  echo "Patched $changed item(s). Reload with: hyprctl reload"
else
  echo "Nothing to change."
fi
