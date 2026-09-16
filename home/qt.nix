# Qt/KDE theming — Breeze, following the session's dark/light mode.
#
# SCOPE
#   Everything Qt in the session: Dolphin, qdirstat, OBS, flashprint. GTK is
#   NOT touched — caelestia owns that side (adw-gtk3-dark + a generated
#   gtk.css) and ./themes.nix owns the gtk/icon/cursor gsettings triplet.
#
# WHY THIS EXISTS AT ALL
#   caelestia's `apply_qt` (caelestia/utils/theme.py) writes its generated
#   palette to ~/.config/qtengine/. qtengine is AUR-only, so on NixOS that
#   directory is written and never read: the Qt half of the theme has been
#   dead the whole time. ./caelestia.nix papered over it by pointing
#   QT_QPA_PLATFORMTHEME at qt6ct instead, but nothing ever wrote qt6ct.conf,
#   so it sat on whatever was hand-set in July 2026 — a Catppuccin Mocha
#   palette, Tokyonight-Dark icons, and `style=kvantum` naming a style plugin
#   that isn't even installed. Dark/light did nothing to it.
#
# WHAT IT DOES INSTEAD
#   QT_QPA_PLATFORMTHEME=kde (the patch in ./caelestia.nix) hands Qt apps to
#   plasma-integration, which is the real KDE platform theme: it reads
#   ~/.config/kdeglobals, and — importantly — it listens on the session bus
#   for org.kde.KGlobalSettings.notifyChange and re-applies the palette to
#   ALREADY-RUNNING apps when it arrives (khintssettings.cpp:193-233, 235-271).
#   That signal is what makes the switch live instead of next-launch.
#
#   So: a small daemon watches the one signal that actually means "the session
#   went dark/light" and rewrites kdeglobals from Breeze's own colour scheme
#   files. No Plasma session, no plasma-workspace, no KCM involved.
#
# THE DARK/LIGHT SIGNAL
#   `caelestia scheme` writes /org/gnome/desktop/interface/color-scheme as
#   prefer-dark / prefer-light on every scheme change (theme.py:317), next to
#   icon-theme (Papirus-Dark / Papirus-Light). That dconf key is the only
#   session-wide dark/light truth here, and it is already what GTK follows —
#   which is exactly why the icon theme is mirrored from it rather than pinned
#   to Breeze's own: Dolphin and the GTK apps then draw the same icons.
{ config, pkgs, lib, ... }:
let
  breeze = pkgs.kdePackages.breeze;

  # kdeglobals rewriter + dconf watcher.
  #
  # Deliberately a whole-file merge rather than a pile of `kwriteconfig6
  # --group Colors:View --key ...` calls: a colour scheme is ~100 keys across
  # 10 groups, and the groups that the OLD scheme had but the new one doesn't
  # have to be dropped, which per-key writes can't express. The non-colour
  # keys in kdeglobals are preserved, which matters — ../home/mime.nix owns
  # General/TerminalApplication there, and KDE apps write their own state into
  # the same file at runtime.
  colourSync = pkgs.writers.writePython3Bin "kde-color-sync" {
    flakeIgnore = [ "E501" ];
  } ''
    """Keep kdeglobals' colour scheme in step with the session's dark/light mode."""

    import configparser
    import os
    import subprocess
    import sys

    SCHEMES = "${breeze}/share/color-schemes"
    GSETTINGS = "${pkgs.glib.bin}/bin/gsettings"
    DBUS_SEND = "${pkgs.dbus}/bin/dbus-send"

    CONFIG = os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
        "kdeglobals",
    )

    # KHintsSettings::ChangeType, plasma-integration qt6/src/platformtheme.
    PALETTE_CHANGED = 0
    ICON_CHANGED = 4

    # Groups a colour scheme owns outright. Anything matching is dropped before
    # the new scheme is merged in, so switching never leaves stale groups behind.
    OWNED = ("Colors:", "ColorEffects:", "WM")


    def ini():
        """A parser that round-trips kdeglobals without mangling it.

        optionxform must not lowercase (KDE keys are CamelCase), ':' must not be
        a delimiter (group names like [Colors:View] and time values would split),
        and interpolation must be off (RawConfigParser) because colour values and
        font strings contain '%' and '$'.
        """
        parser = configparser.RawConfigParser(
            strict=False,
            allow_no_value=True,
            delimiters=("=",),
            comment_prefixes=("#",),
            inline_comment_prefixes=None,
        )
        parser.optionxform = str
        return parser


    def gsetting(key, fallback):
        try:
            result = subprocess.run(
                [GSETTINGS, "get", "org.gnome.desktop.interface", key],
                capture_output=True, text=True, timeout=10, check=True,
            )
        except (OSError, subprocess.SubprocessError):
            return fallback
        return result.stdout.strip().strip("'\"") or fallback


    def notify(change):
        """Tell running Qt apps to re-read kdeglobals.

        plasma-integration connects to this signal at startup; without it the
        file changes and nothing on screen does until the app is restarted.
        """
        subprocess.run(
            [
                DBUS_SEND, "--session", "--type=signal", "/KGlobalSettings",
                "org.kde.KGlobalSettings.notifyChange",
                "int32:" + str(change), "int32:0",
            ],
            check=False,
        )


    def apply():
        dark = "dark" in gsetting("color-scheme", "prefer-dark")
        scheme = "BreezeDark" if dark else "BreezeLight"
        icons = gsetting("icon-theme", "Papirus-Dark" if dark else "Papirus-Light")

        current = ini()
        current.read(CONFIG, encoding="utf-8")

        already = (
            current.get("General", "ColorScheme", fallback=None) == scheme
            and current.get("Icons", "Theme", fallback=None) == icons
        )
        if already:
            return

        for section in list(current.sections()):
            if section.startswith(OWNED):
                current.remove_section(section)

        wanted = ini()
        wanted.read(os.path.join(SCHEMES, scheme + ".colors"), encoding="utf-8")
        for section in wanted.sections():
            if not current.has_section(section):
                current.add_section(section)
            for key, value in wanted.items(section):
                # ~90 translations of the scheme's display name. Plasma copies
                # them; nothing reads them out of kdeglobals.
                if key.startswith("Name["):
                    continue
                current.set(section, key, value)

        # widgetStyle is set explicitly even though plasma-integration already
        # defaults to breeze — so `hyprctl`-less debugging of "which style am I
        # running" has an answer in the file.
        for section, key, value in (
            ("General", "ColorScheme", scheme),
            ("Icons", "Theme", icons),
            ("KDE", "widgetStyle", "Breeze"),
        ):
            if not current.has_section(section):
                current.add_section(section)
            current.set(section, key, value)

        # Atomic: KDE apps read this file at arbitrary moments.
        staging = CONFIG + ".kde-color-sync"
        with open(staging, "w", encoding="utf-8") as handle:
            current.write(handle, space_around_delimiters=False)
        os.replace(staging, CONFIG)

        notify(PALETTE_CHANGED)
        notify(ICON_CHANGED)


    def main():
        apply()
        if "--watch" not in sys.argv[1:]:
            return

        # `gsettings monitor <schema>` prints "<key>: <value>" per change. dconf
        # is what caelestia writes, and dconf's change notification is what this
        # reads back — no polling.
        monitor = subprocess.Popen(
            [GSETTINGS, "monitor", "org.gnome.desktop.interface"],
            stdout=subprocess.PIPE, text=True,
        )
        for line in monitor.stdout:
            if line.split(":", 1)[0] in ("color-scheme", "icon-theme"):
                apply()


    main()
  '';
in
{
  home.packages = [
    # The QPA plugin QT_QPA_PLATFORMTHEME=kde names. Found via QT_PLUGIN_PATH,
    # which is already profile-relative — `qt.enable` is on system-side, so
    # /etc/profiles/per-user/$USER/lib/qt-6/plugins is on the search path.
    pkgs.kdePackages.plasma-integration

    # The Breeze Qt6 widget style AND the Breeze{Light,Dark}.colors the daemon
    # above reads. Same package, both halves needed.
    breeze

    # Icon fallback. Papirus is the icon theme in use (mirrored from GTK), but
    # it doesn't cover every KDE-specific name; Dolphin's own closure carries
    # breeze-icons, the other Qt apps' don't.
    pkgs.kdePackages.breeze-icons

    # KDE's file dialog, used by plasma-integration in place of Qt's own.
    pkgs.kdePackages.kio

    colourSync
  ];

  # ── The daemon.
  #
  # WantedBy default.target, not graphical-session.target: this session starts
  # Hyprland without uwsm and never reaches graphical-session.target (it reads
  # `inactive`), so a unit hung off it would simply never run. default.target
  # is active from login. Nothing here needs a compositor anyway — it writes a
  # file and emits a D-Bus signal, both fine with no windows on screen.
  systemd.user.services.kde-color-sync = {
    Unit = {
      Description = "Follow the session dark/light mode with a Breeze colour scheme";
      After = [ "dconf.service" ];
    };
    Service = {
      ExecStart = "${colourSync}/bin/kde-color-sync --watch";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };

  # Without this home-manager only *prints* that the unit changed, and the old
  # store path keeps running until the next login — which for a long-lived
  # watcher means a rebuild appears to do nothing.
  systemd.user.startServices = "sd-switch";
}
