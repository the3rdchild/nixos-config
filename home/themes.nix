# Theme switcher for GTK / icons / cursor — inspired by HyDE's curated gallery.
#
# SCOPE
#   This module manages ONLY the GTK (gtk-theme), icon-theme, and cursor-theme
#   for the user session. Everything the shell draws — the bar, launcher,
#   notifications, foot, btop — is coloured from the current wallpaper by the
#   session's own matugen pipeline (see ./ii-session.nix) and must not be
#   pinned here.
#
#   All three keys land in dconf, which is the one place both this module and
#   the session's own theming scripts read. `themes.activeCursor` used to be
#   exported for ./caelestia.nix to bake into hypr-vars.lua; with that session
#   gone the cursor reaches Hyprland through dconf like everything else.
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

  # ── The GTK theme name, corrected per dark/light mode.
  #
  # WHY THIS IS NEEDED
  #   It was written for caelestia's apply_gtk (utils/theme.py:316), which
  #   wrote the dconf gtk-theme key unconditionally as "adw-gtk3-dark" — the
  #   DARK variant, even when the line immediately below it was writing
  #   prefer-light. A genuine upstream bug, invisible in the shell (which
  #   coloured itself from scheme.json) and visible only in GTK apps.
  #
  #   That session is gone and its successor gets this right: switchwall.sh's
  #   pre_process() writes gtk-theme and color-scheme as a matching pair (see
  #   the dconf patch in ./ii-session.nix). This watcher is kept anyway —
  #   ./theme-switch and any hand-run `dconf write` still set color-scheme on
  #   its own, and this is what keeps gtk-theme from being left behind.
  #
  #   Two things made it worse here. adw-gtk3 was not installed at all, so
  #   GTK3 fell back to Adwaita; and ~/.config/gtk-3.0/settings.ini still
  #   carried plasma6-era values naming two themes that do not exist. The net
  #   effect was a GTK stack where flipping the mode changed almost nothing —
  #   LibreOffice in particular ended up recolouring its text and not its
  #   background.
  #
  # WHY dconf AND NOT settings.ini
  #   On Wayland GTK3 reads gtk-theme-name from the xdg settings portal, and
  #   the portal serves this dconf key. settings.ini is OUTRANKED — measured
  #   with gtk-query-settings, which reported adw-gtk3-dark while settings.ini
  #   was asking for Flat-Remix-GTK-Blue-Dark. So the fix has to land on dconf.
  #
  # WHY A WATCHER AND NOT A PATCH
  #   Patching the CLI derivation was tried first and silently did nothing:
  #   the postPatch landed in the .drv, the anchor matched when run by hand,
  #   and the built output was still unmodified. A patch that can no-op
  #   without failing the build is worse than no patch.
  #
  # WHY NO prefer-dark HANDLING
  #   adw-gtk3 and adw-gtk3-dark are separate theme trees, each with its own
  #   gtk.css. Once the name is right the mode is already decided, so
  #   gtk-application-prefer-dark-theme only has to be false and stay false —
  #   asserted once in the activation below. Both trees also ship a
  #   gtk-dark.css, which is exactly why leaving it at the inherited `true`
  #   would have kept the light variant dark.
  gtkThemeSync = pkgs.writeShellScriptBin "gtk-theme-sync" ''
    set -euo pipefail
    export PATH="${pkgs.dconf}/bin:$PATH"

    iface=/org/gnome/desktop/interface

    apply() {
      case "$(dconf read $iface/color-scheme)" in
        *dark*) want="'adw-gtk3-dark'" ;;
        *)      want="'adw-gtk3'" ;;
      esac
      # Guarded so writing the key cannot wake this loop into a cycle.
      if [ "$(dconf read $iface/gtk-theme)" != "$want" ]; then
        dconf write $iface/gtk-theme "$want"
      fi
    }

    apply

    # `dconf watch` prints the changed key's full path, then its value. Only
    # color-scheme matters; the colour pipeline writes it immediately AFTER gtk-theme
    # (theme.py:316 then 317), so by the time this fires the wrong value is
    # already in place and this overwrites it.
    dconf watch $iface/ | while read -r line; do
      if [ "$line" = "$iface/color-scheme" ]; then
        apply
      fi
    done

    # Only reached if `dconf watch` died; make that a failure so systemd
    # restarts instead of leaving the mode unwatched.
    exit 1
  '';

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
    echo "NOTE: the shell/foot/btop palette is NOT changed — it is derived"
    echo "      from the wallpaper by the session's own colour pipeline."
    echo "      Change the wallpaper to change those."
  '';
in
{
  options.themes = {
    active = lib.mkOption {
      type = lib.types.enum (lib.attrNames themes);
      default = "catppuccin-mocha";
      description = "Active theme key (see registry in home/themes.nix).";
    };

    # Nothing reads this any more — ./caelestia.nix did, to bake the name
    # into hypr-vars.lua. Kept because it is the one place the active
    # cursor's name is stated as a value rather than looked up, and it costs
    # nothing: readOnly, derived, no config it can contradict.
    activeCursor = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = activeTheme.cursor;
      description = "Cursor theme name of the active theme.";
    };
  };

  config = {
    # 1. Install ALL theme packages so any switch is instant.
    home.packages = allPackages ++ [
      themeSwitch
      gtkThemeSync

      # Not one of the registry themes above and deliberately not in it: this
      # is the theme switchwall.sh's pre_process() writes to dconf on every
      # wallpaper change, so it has to exist no matter which entry
      # `themes.active` points at. Ships both the adw-gtk3 and adw-gtk3-dark
      # trees.
      pkgs.adw-gtk3
    ];

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

    # 3. Keep the GTK theme name in step with the mode (see gtkThemeSync).
    #    default.target, not graphical-session.target: the plain "Hyprland"
    #    fallback session never reaches the latter (the UWSM default does).
    #    Same reasoning as the Qt watcher in ./qt.nix.
    systemd.user.services.gtk-theme-sync = {
      Unit = {
        Description = "Point dconf's gtk-theme at the adw-gtk3 variant matching the session mode";
        After = [ "dconf.service" ];
      };
      Service = {
        ExecStart = "${gtkThemeSync}/bin/gtk-theme-sync";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "default.target" ];
    };

    # 4. Prune ~/.config/gtk-3.0/settings.ini.
    #
    #    Every key deleted here names something that is not installed
    #    (Flat-Remix-GTK-Blue-Dark, breeze-dark, breeze_cursors,
    #    colorreload-gtk-module) and is already outranked by the portal, so
    #    removing them changes nothing at runtime — it stops the file from
    #    lying about what the session uses. prefer-dark is the one key the
    #    portal does NOT serve, so it is the one that still had teeth: left at
    #    the inherited `true` it pulls gtk-dark.css out of whichever adw-gtk3
    #    tree is selected and undoes the switcher above.
    #
    #    Asserted key by key rather than owning the file, for the reason in
    #    the header — except the reason has changed: the JaKooLit dots that
    #    used to rewrite it are gone with the move to caelestia, and nothing
    #    writes it now. It is kept mutable because GTK may yet want to.
    home.activation.gtk3Settings = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      let
        kwriteconfig = "${pkgs.kdePackages.kconfig}/bin/kwriteconfig6";
        ini = "${config.xdg.configHome}/gtk-3.0/settings.ini";
        stale = [ "gtk-theme-name" "gtk-icon-theme-name" "gtk-cursor-theme-name" "gtk-modules" ];
      in
      lib.concatStringsSep "\n" (
        [ ''run ${kwriteconfig} --file ${ini} --group Settings --key gtk-application-prefer-dark-theme false'' ]
        ++ map (key: ''run ${kwriteconfig} --file ${ini} --group Settings --key ${key} --delete ""'') stale
      )
    );

    # 5. Provide a stable cache dir for cursor rendering (some apps need it).
    xdg.configFile."gtk-3.0/.keep".text = "";   # ensure dir exists
  };
}
