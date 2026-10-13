# Writes the theme half of kitty.conf that changes with light/dark mode and
# reloads kitty live.
#
# Only for the home-manager root (~/.config/kitty). ./ii-session's own
# kitty.conf already follows the wallpaper through matugen (see
# ./ii-session/terminals.nix) — this script never touches ~/.config-ii, so
# the two mechanisms don't fight over the same file.
#
# kitty.conf's `include theme-auto.conf` is the one line that never changes;
# this is the file that line includes. Written as a sibling of kitty.conf
# rather than replacing it outright, because home-manager's symlink is
# kitty.conf itself — the directory around it stays a real, writable dir.
{ pkgs }:

pkgs.writeShellScriptBin "kitty-theme-settings" ''
  set -euo pipefail

  root="''${XDG_CONFIG_HOME:-$HOME/.config}"
  target="$root/kitty/theme-auto.conf"

  dark='foreground #a9b1d6
  background #1a1b26

  color0 #414868
  color8 #414868

  color1 #f7768e
  color9 #f7768e

  color2  #73daca
  color10 #73daca

  color3  #e0af68
  color11 #e0af68

  color4  #7aa2f7
  color12 #7aa2f7

  color5  #bb9af7
  color13 #bb9af7

  color6  #7dcfff
  color14 #7dcfff

  color7  #c0caf5
  color15 #c0caf5

  cursor #c0caf5
  cursor_text_color #1a1b26

  selection_foreground none
  selection_background #28344a

  url_color #9ece6a

  active_border_color #3d59a1
  inactive_border_color #101014
  bell_border_color #e0af68

  active_tab_foreground   #3d59a1
  active_tab_background   #16161e
  inactive_tab_foreground #787c99
  inactive_tab_background #16161e
  tab_bar_background #101014

  macos_titlebar_color #16161e
  wayland_titlebar_color #16161e'

  light='foreground #504e55
  background #fcfcfc

  color0  #fcfcfc
  color8  #9a9996

  color1  #ed333b
  color9  #f66151

  color2  #57e389
  color10 #8ff0a4

  color3  #ff7800
  color11 #ffa348

  color4  #62a0ea
  color12 #99c1f1

  color5  #9141ac
  color13 #dc8add

  color6  #5bc8af
  color14 #93ddc2

  color7  #deddda
  color15 #f6f5f4

  cursor #504e55
  cursor_text_color #fcfcfc

  selection_foreground #5e5c64
  selection_background #deddda

  url_color #1a5fb4

  active_border_color #c0bfbc
  inactive_border_color #f6f5f4
  bell_border_color #ed333b

  active_tab_foreground   #504e55
  active_tab_background   #b0afac
  inactive_tab_foreground #5e5c64
  inactive_tab_background #deddda
  tab_bar_background none

  macos_titlebar_color system
  wayland_titlebar_color system'

  mode=dark
  value="$(${pkgs.dconf}/bin/dconf read /org/gnome/desktop/interface/color-scheme 2>/dev/null | tr -d "'" || true)"
  case "$value" in
    prefer-light|default) mode=light ;;
  esac

  content="$dark"
  case "$mode" in
    light) content="$light" ;;
  esac

  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ] && [ "$(cat "$target")" = "$content" ]; then
    exit 0
  fi
  printf '%s\n' "$content" > "$target"

  pid="$(${pkgs.procps}/bin/pidof kitty || true)"
  [ -n "$pid" ] && kill -SIGUSR1 $pid || true
''
