# Theme switcher for GTK / icons / cursor — inspired by HyDE's curated gallery.
#
# SCOPE
#   This module manages ONLY the GTK (gtk-theme), icon-theme, and cursor-theme
#   for the user session. Everything caelestia draws — the bar, launcher,
#   notifications, foot, btop — is coloured by `caelestia scheme` from the
#   current wallpaper and must not be pinned here.
#
#   The cursor is the one value both sides care about, so `themes.activeCursor`
#   is exported and baked into hypr-vars.lua by ./caelestia.nix. Change the
#   theme here and the Hyprland cursor follows on next login.
#
# WHAT IT DOES
#   1. Defines a small, curated registry of themes (Catppuccin / Tokyo Night /
#      Gruvbox / Nord / Graphite) with their GTK theme + icon + cursor triplet.
#   2. Installs ALL of them system-wide so a switch is instant — no rebuild.
#   3. Sets the active one declaratively via `themes.active` (default: mocha).
#   4. Ships a `theme-switch <name>` helper for runtime switching that simply
#      flips the same `gsettings` keys the dots already use.
#
# WHY NOT JUST home-manager `gtk.{theme,iconTheme,cursorTheme}`?
#   home-manager's gtk options write a read-only `~/.config/gtk-3.0/settings.ini`
#   which fights with the JaKooLit dots (initial-boot.sh / DarkLight.sh rewrite
#   it via gsettings at login). The dots MUST keep writing that file. So we
#   keep the switcher at the gsettings layer (mutable) and only ship the theme
#   *packages* + a thin wrapper around gsettings. No home-manager gtk block.
{ config, pkgs, lib, ... }:
let
  cfg = config.themes;

  # ── Theme packages ──────────────────────────────────────────────────────
  # Catppuccin GTK is a single attr overridden per variant; build all four so
  # a switch is instant. The internal theme name (what gsettings sees) is
  # `catppuccin-<variant>-<accent>-<size>`.
  catppuccinVariant = variant: accent:
    pkgs.catppuccin-gtk.override {
      inherit variant;
      accents = [ accent ];
      size = "standard";
      tweaks = [ ];
    };

  # ── The registry ────────────────────────────────────────────────────────
  # Each entry is a complete visual identity. Keep `gtk`, `icon`, `cursor`
  # as the gsettings values; `pkgs.gtk`/`pkgs.icon`/`pkgs.cursor` are the
  # nix packages that install those theme directories under /share.
  themes = {
    catppuccin-mocha = {
      label = "Catppuccin Mocha";
      gtk   = "catppuccin-mocha-mauve-standard+default";
      icon  = "Papirus-Dark";
      cursor = "catppuccin-mocha-dark-cursors";
      packages = [
        (catppuccinVariant "mocha" "mauve")
        pkgs.papirus-icon-theme
        pkgs.catppuccin-cursors.mochaDark
      ];
    };
    catppuccin-macchiato = {
      label = "Catppuccin Macchiato";
      gtk   = "catppuccin-macchiato-lavender-standard+default";
      icon  = "Papirus-Dark";
      cursor = "catppuccin-macchiato-dark-cursors";
      packages = [
        (catppuccinVariant "macchiato" "lavender")
        pkgs.papirus-icon-theme
        pkgs.catppuccin-cursors.macchiatoDark
      ];
    };
    catppuccin-latte = {
      label = "Catppuccin Latte";
      gtk   = "catppuccin-latte-mauve-standard+default";
      icon  = "Papirus";
      cursor = "catppuccin-latte-dark-cursors";
      packages = [
        (catppuccinVariant "latte" "mauve")
        pkgs.papirus-icon-theme
        pkgs.catppuccin-cursors.latteDark
      ];
    };
    tokyo-night = {
      label = "Tokyo Night";
      gtk   = "Tokyonight-Dark";
      icon  = "Papirus-Dark";
      cursor = "Bibata-Original-Classic";
      packages = [
        pkgs.tokyonight-gtk-theme
        pkgs.papirus-icon-theme
        pkgs.bibata-cursors
      ];
    };
    gruvbox = {
      label = "Gruvbox";
      gtk   = "Gruvbox-Dark-B";   # gruvbox-gtk-theme ships -B/-L/-G variants
      icon  = "Gruvbox-Plus-Dark";
      cursor = "Bibata-Original-Classic";
      packages = [
        pkgs.gruvbox-gtk-theme
        pkgs.papirus-icon-theme   # gruvbox icon set is unreliable in nixpkgs
        pkgs.bibata-cursors
      ];
    };
    nord = {
      label = "Nordic";
      gtk   = "Nordic";
      icon  = "Papirus-Dark";
      cursor = "Bibata-Original-Classic";
      packages = [
        pkgs.nordic
        pkgs.papirus-icon-theme
        pkgs.bibata-cursors
      ];
    };
    graphite = {
      label = "Graphite";
      gtk   = "Graphite-Dark";   # graphite-gtk-theme; verify variant list on switch
      icon  = "Papirus-Dark";
      cursor = "graphite-light-cursors";   # graphite-cursors
      packages = [
        pkgs.graphite-gtk-theme
        pkgs.papirus-icon-theme
        pkgs.graphite-cursors
      ];
    };
  };

  activeTheme = themes.${cfg.active};

  # Flatten every package across every theme so all are installed and a
  # `theme-switch` is instant without a rebuild.
  allPackages = lib.flatten (lib.mapAttrsToList (_: t: t.packages) themes);

  # The runtime switcher. Reads the registry above (baked at build time) so
  # it doesn't need to know about Nix. Mirrors what the dots' DarkLight.sh
  # does but for any registered theme.
  themeSwitch = pkgs.writeShellScriptBin "theme-switch" ''
    set -euo pipefail
    usage() {
      cat <<EOF
    Usage: theme-switch <name>
    Available themes:
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: t: "  ${n}  - ${t.label}") themes)}
    Current: ${cfg.active}
    EOF
    }

    if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
      usage
      exit 0
    fi

    name="$1"

    case "$name" in
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: t: ''
      ${n})
        gtk="${t.gtk}"
        icon="${t.icon}"
        cursor="${t.cursor}"
        ;;
    '') themes)}
      *)
        echo "Unknown theme: $name" >&2
        usage
        exit 1
        ;;
    esac

    # gsettings lives in PATH via the user session (dconf from dconf module).
    # We still add glib.bin for `gsettings` if invoked outside a session.
    export PATH="${pkgs.glib.bin}/bin:${pkgs.dconf}/bin:$PATH"

    gsettings set org.gnome.desktop.interface gtk-theme       "$gtk"
    gsettings set org.gnome.desktop.interface icon-theme      "$icon"
    gsettings set org.gnome.desktop.interface cursor-theme    "$cursor"

    # Prefer-dark unless the theme name suggests light (latte/gruvbox-light).
    case "$name" in
      catppuccin-latte|*-light) color="default" ;;
      *)                        color="prefer-dark" ;;
    esac
    gsettings set org.gnome.desktop.interface color-scheme "$color"

    echo "Switched to: $name ($gtk / $icon / $cursor)"
    echo "NOTE: the caelestia shell/foot/btop palette is NOT changed — it is"
    echo "      derived from the wallpaper. Use 'caelestia scheme' for those."
    echo "      The Hyprland cursor updates at next login (hypr-vars.lua)."
  '';
in
{
  options.themes = {
    active = lib.mkOption {
      type = lib.types.enum (lib.attrNames themes);
      default = "catppuccin-mocha";
      description = "Active theme key (see registry in home/themes.nix).";
    };

    # Read by home/caelestia.nix, which bakes it into hypr-vars.lua so the
    # cursor execs.lua sets at session start matches the one applied here.
    activeCursor = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = activeTheme.cursor;
      description = "Cursor theme name of the active theme.";
    };
  };

  config = {
    # 1. Install ALL theme packages so any switch is instant.
    home.packages = allPackages ++ [ themeSwitch ];

    # 2. Set the active theme at activation (one-time, per rebuild). The dots'
    #    own initial-boot.sh / DarkLight.sh run later at login and will pick
    #    up these gsettings values. We don't touch settings.ini directly —
    #    the dots own that file.
    home.activation.applyTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${pkgs.glib.bin}/bin:${pkgs.dconf}/bin:$PATH"
      gsettings set org.gnome.desktop.interface gtk-theme     "${activeTheme.gtk}" 2>/dev/null || true
      gsettings set org.gnome.desktop.interface icon-theme    "${activeTheme.icon}" 2>/dev/null || true
      gsettings set org.gnome.desktop.interface cursor-theme  "${activeTheme.cursor}" 2>/dev/null || true
    '';

    # 3. Provide a stable cache dir for cursor rendering (some apps need it).
    xdg.configFile."gtk-3.0/.keep".text = "";   # ensure dir exists
  };
}
