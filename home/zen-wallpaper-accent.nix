{ pkgs }:
#
# Zen's accent colour, derived from the wallpaper.
#
# Zen already follows the session's light/dark on its own: it is Firefox, it
# reads org.freedesktop.appearance color-scheme from the portal, and
# xdg-desktop-portal-gtk serves that from the same
# org.gnome.desktop.interface color-scheme key ../home/ii-session.nix's
# switchwall patch writes. Nothing here touches light/dark — the one thing
# that breaks it is a static theme pinned in about:addons, which is a profile
# setting rather than anything Nix can assert.
#
# The accent is the half that never worked. Zen's own knob is the
# `zen.theme.accent-color` pref, whose default is the string "AccentColor" —
# the CSS system colour, which Firefox on Linux derives from a GTK button
# styled .suggested-action. Inside the flatpak sandbox that resolves against
# the runtime's stock Adwaita: the app has no --filesystem=xdg-config/gtk-3.0
# and no org.gtk.Gtk3theme.* extension (`flatpak info --show-permissions`), so
# the wallpaper's palette is simply not visible to it. It is blue, always.
#
# So the palette is pushed in as CSS instead. userChrome.css (asserted by
# ./zen.nix) imports the file written here and maps it onto Zen's accent
# variables. userChrome.css is loaded as a USER sheet, and a user-origin
# !important outranks an author inline style — which matters, because
# chrome://browser/content/zenThemeModifier.js sets --zen-primary-color
# inline on documentElement from that pref.
#
# What this cannot do is apply without a restart. Firefox reads userChrome.css
# once at startup and offers no way in: prefs are only read from disk at
# startup too, Zen Mods rebuild on a pref observer rather than a file watch
# (zen-components/ZenMods.mjs:527), the appearance portal exposes no
# accent-color here (xdg-desktop-portal-gtk 1.15.3 has no such setting), and
# GTK3 does not monitor the user gtk.css it parsed at startup. Hence `auto
# on`, below: the honest way to get "change the wallpaper, Zen follows" is to
# restart Zen, and that is a choice to make deliberately rather than a default.
let
  inherit (pkgs) lib;
in
pkgs.writeShellScriptBin "ii-zen-accent" ''
  set -eu

  # /run/current-system/sw/bin last, for flatpak only. The system flatpak is
  # the one whose D-Bus service and installation state this machine's apps
  # were installed against; a second copy out of the store would be a
  # different build talking to the same ~/.local/share/flatpak.
  export PATH=${lib.makeBinPath [
    pkgs.jq
    pkgs.coreutils
    pkgs.diffutils
    pkgs.gnused
    pkgs.procps
    pkgs.libnotify
    pkgs.systemd
  ]}:/run/current-system/sw/bin

  # Overridable, because the unit in ../home/ii-session.nix has to name
  # session B's palette explicitly: it runs under systemd --user, which is
  # session A's environment, so $XDG_CONFIG_HOME here is ~/.config and not
  # ~/.config-ii.
  colors="''${ZEN_ACCENT_COLORS:-$HOME/.local/state/quickshell/user/generated/colors.json}"

  # State, not config, and deliberately not under either session's config
  # root. Both sessions share ~/.local/state (it is where the shell's own
  # generated palette lives), so `ii-zen-accent auto on` means the same thing
  # from either one — under XDG_CONFIG_HOME it would have written to
  # ~/.config-ii from session B and ~/.config from session A, and the second
  # of those would have been a toggle the unit never reads.
  flag="''${ZEN_ACCENT_FLAG:-''${XDG_STATE_HOME:-$HOME/.local/state}/ii-zen-accent/restart}"

  zenroot="$HOME/.var/app/app.zen_browser.zen/.zen"

  # The profile is read rather than hardcoded. ./zen.nix does hardcode it —
  # home.file needs a static path — but this runs at a point where guessing
  # wrong is silent, and installs.ini is the file Zen itself consults.
  zen_profile() {
    sed -n 's/^Default=//p' "$zenroot/installs.ini" 2>/dev/null | head -1
  }

  restart_state() { [ "$(cat "$flag" 2>/dev/null)" = "1" ] && echo on || echo off; }

  # SIGTERM, not `flatpak kill` (which is SIGKILL): Firefox saves its session
  # on a clean shutdown and loses the open tabs on a hard one. Only the parent
  # is signalled — the content processes follow it down on their own — and the
  # pattern is the exact cmdline so it cannot match this script.
  zen_pid() { pgrep -f '^/app/zen/zen --name app.zen_browser.zen$' 2>/dev/null | head -1; }

  restart_zen() {
    pid="$(zen_pid)"
    [ -n "$pid" ] || return 0
    kill -TERM "$pid" 2>/dev/null || return 0
    for _ in $(seq 1 100); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    # systemd-run, so the new browser is not a child of this oneshot service
    # and does not get killed the moment it exits. `flatpak run` still makes
    # its own app-flatpak-app.zen_browser.zen-<hex>.scope, which is what
    # ../home/app-limits.nix caps, so the memory limit survives the relaunch.
    systemd-run --user --collect --quiet \
      --unit="zen-relaunch-$$" -- flatpak run app.zen_browser.zen >/dev/null 2>&1 || true
  }

  apply() {
    force_restart="$1"

    [ -f "$colors" ] || exit 0
    profile="$(zen_profile)"
    [ -n "$profile" ] || exit 0
    chromedir="$zenroot/$profile/chrome"
    [ -d "$zenroot/$profile" ] || exit 0

    # Accent only, as asked. Every name here is a matugen role that exists in
    # both modes and flips with it, so one palette per generation is enough —
    # the mode and the palette are always rewritten by the same switchwall run
    # and can never disagree.
    vars="$(jq -r '
      {
        "primary":              .primary,
        "on-primary":           .on_primary,
        "primary-container":    .primary_container,
        "on-primary-container": .on_primary_container,
        "secondary":            .secondary,
        "tertiary":             .tertiary,
        "outline":              .outline
      }
      | with_entries(select(.value != null))
      | to_entries
      | map("  --ii-wp-\(.key): \(.value);")
      | join("\n")
    ' "$colors" 2>/dev/null || true)"
    # `|| true` because of set -e: a truncated colours.json makes jq exit 1,
    # and an assignment carries its command's status, so without it the
    # script would abort here instead of reaching this check — and a oneshot
    # that aborts is a unit systemd marks failed for a file that is merely
    # mid-write. Nothing is lost by waiting: the close that finishes the
    # write is itself a PathChanged, so the next run sees the whole file.
    [ -n "$vars" ] || exit 0

    mkdir -p "$chromedir"
    out="$chromedir/zen-wallpaper-accent.css"
    tmp="$out.new"
    {
      echo "/* Generated by ii-zen-accent from $colors. Do not edit. */"
      echo ":root {"
      echo "$vars"
      echo "}"
    } > "$tmp"

    # Unchanged palette, nothing to say. Without this every regeneration that
    # did not actually move a colour would still fire a notification, and
    # switchwall regenerates on more occasions than a wallpaper change.
    if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
      rm -f "$tmp"
      return 0
    fi
    mv "$tmp" "$out"

    [ -n "$(zen_pid)" ] || return 0
    if [ "$force_restart" = "1" ] || [ "$(restart_state)" = "on" ]; then
      restart_zen
    else
      notify-send -a Zen -i app.zen_browser.zen \
        "Zen: aksen wallpaper diperbarui" \
        "Buka ulang Zen untuk menerapkannya, atau \`ii-zen-accent auto on\` agar otomatis." \
        2>/dev/null || true
    fi
  }

  case "''${1:-apply}" in
    apply)     apply 0 ;;
    --restart) apply 1 ;;
    auto)
      case "''${2:-status}" in
        status) echo "zen accent auto-restart: $(restart_state)" ;;
        on|off)
          mkdir -p "$(dirname "$flag")"
          [ "$2" = "on" ] && echo 1 > "$flag" || echo 0 > "$flag"
          echo "zen accent auto-restart: $(restart_state)"
          ;;
        toggle) [ "$(restart_state)" = "on" ] && exec "$0" auto off || exec "$0" auto on ;;
        *) echo "usage: ii-zen-accent auto [status|on|off|toggle]" >&2; exit 2 ;;
      esac
      ;;
    *) echo "usage: ii-zen-accent [apply|--restart|auto [status|on|off|toggle]]" >&2; exit 2 ;;
  esac
''
