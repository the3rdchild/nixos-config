{ config, lib, pkgs, ... }:
let
  cfgDirName = ".config-ii";

  # ── How session B starts.
  #
  # Setting XDG_CONFIG_HOME is the whole mechanism. Hyprland looks for its
  # config under $XDG_CONFIG_HOME/hypr before $HOME/.config/hypr and picks up
  # hyprland.lua on its own — verified with `XDG_CONFIG_HOME=... Hyprland
  # --verify-config`, which reported "Using lua config found at
  # <dir>/hypr/hyprland.lua". So no -c is needed, and more importantly every
  # other program launched from this session reads the same alternate root
  # without being told: fish, kitty, foot, fontconfig, kdeglobals, Kvantum,
  # matugen, fuzzel, dconf. That is what keeps the caelestia session's
  # ~/.config completely untouched.
  #
  # start-hyprland, not Hyprland, to match the plain session entry that ships
  # in the Hyprland package — it is the watchdog wrapper.
  #
  # Deliberately NOT uwsm. Under uwsm the compositor runs as a user unit and
  # graphical-session.target is reached, which would start the caelestia shell,
  # the polkit agent and both cliphist watchers (../home/caelestia.nix) on top
  # of this session — two shells fighting over the same layer surfaces. Plain
  # Hyprland never reaches that target, so those units stay asleep and ii's own
  # execs.lua starts its equivalents. This is the same fallback path the plain
  # "Hyprland" entry already uses.
  # ── QML modules quickshell doesn't carry.
  #
  # Session B reuses the quickshell that comes in with caelestia's flake
  # (quickshell-wrapped 0.3.1) rather than building a second one. That wrapper
  # only puts qtdeclarative, qtwayland and m3shapes on the QML import path,
  # which is enough for caelestia and not for these dots: ii and end4-pC import
  # five modules it has never heard of. Without them the shell dies at load
  # with "module <x> is not installed" and no bar ever appears.
  #
  # NIXPKGS_QT6_QML_IMPORT_PATH rather than a second wrapper binary around qs:
  # nixpkgs' Qt patch reads this variable, the existing wrapper *prefixes* its
  # own paths onto whatever it already holds, and exporting it in the session
  # therefore adds to the search path instead of replacing it. One line, no
  # rewriting of the 17 places these dots spell `qs`, and session A never sees
  # it because it is exported here and nowhere else.
  #
  # kirigami.unwrapped, not kirigami: the wrapped output is a propagation stub
  # holding nothing but nix-support, so its lib/qt-6/qml does not exist. The
  # QML lives in the unwrapped derivation.
  qmlPath = lib.concatMapStringsSep ":" (p: "${p}/lib/qt-6/qml") [
    pkgs.qt6.qt5compat # Qt5Compat.GraphicalEffects
    pkgs.qt6.qtpositioning # QtPositioning
    pkgs.kdePackages.kirigami.unwrapped # org.kde.kirigami — AppIcon.qml, both shells
    pkgs.kdePackages.syntax-highlighting # org.kde.syntaxhighlighting
  ];

  # ── Darkly, the Qt widget style these dots select.
  #
  # The kdeglobals ii ships says `widgetStyle=Darkly` (kdeglobals:152) and it
  # ships a darklyrc beside it, but the style itself was never installed, so
  # every Qt app in session B silently fell back to Breeze.
  #
  # QT_PLUGIN_PATH rather than home.packages, for two reasons. A style plugin
  # sitting in the user profile is not found at all: wrapQtAppsHook bakes a
  # fixed plugin path into each wrapped app, and the profile is not on it.
  # And exporting it here keeps the style out of session A — which selects
  # Breeze explicitly (../home/qt.nix writes widgetStyle=Breeze into
  # ~/.config/kdeglobals), so a visible Darkly there would be a change nobody
  # asked for. The hook *prefixes* its own entries onto QT_PLUGIN_PATH rather
  # than replacing it, so this adds to the search path instead of breaking
  # every other plugin — the same property NIXPKGS_QT6_QML_IMPORT_PATH relies
  # on below.
  #
  # Qt6 only: darkly-qt5 was removed from nixpkgs over its KF5 dependencies,
  # so Qt5 apps here keep falling back. Nothing in these dots is Qt5.
  #
  # kimageformats rides along for the same reason it would otherwise be
  # unreachable. The dolphinrc these dots ship lists `avif` among its
  # thumbnail plugins (dolphinrc:18), and upstream's Arch dependency list
  # names qt6-avif-image-plugin for it — which has no nixpkgs package of that
  # name, but is exactly what kimg_avif.so inside kimageformats is. Same
  # plugin directory, same variable, so it is one more entry here rather than
  # a second mechanism.
  #
  # plasma-workspace is the third entry and the odd one: it is here for its
  # KCMs, not for a style. Config.qml:153-157 opens three settings panels as
  # `kcmshell6 kcm_bluetooth`, `kcm_networkmanagement` and `kcm_users`, and
  # kcmshell6 finds a KCM by scanning plasma/kcms/systemsettings under each
  # plugin path. plasma-nm and bluedevil ship the first two; kcm_users.so
  # ships only inside plasma-workspace, so that button did nothing. Adding the
  # directory takes kcmshell6 --list from 8 modules to 26 — verified — and
  # costs no new store paths, since ../home/ii-session.nix's plasmaTools
  # explains why plasma-workspace is already in the system closure.
  #
  # Safe to put on this variable specifically because of what it does NOT
  # contain: no platformthemes/, no styles/, no iconengines/. It cannot
  # displace Darkly or the platform theme. What it does add beyond the KCMs is
  # kded modules, KIO workers, krunner plugins and Plasma applets — all of
  # them loaded only by daemons this session does not run, and one of which
  # (kded6) ii's own ConflictKiller kills on sight.
  qtPluginPath = lib.concatMapStringsSep ":" (p: "${p}/lib/qt-6/plugins") [
    pkgs.darkly
    pkgs.kdePackages.kimageformats
    pkgs.kdePackages.plasma-workspace
  ];

  launcher = pkgs.writeShellScriptBin "start-hyprland-ii" ''
    export XDG_CONFIG_HOME="$HOME/${cfgDirName}"
    export NIXPKGS_QT6_QML_IMPORT_PATH="${qmlPath}''${NIXPKGS_QT6_QML_IMPORT_PATH:+:$NIXPKGS_QT6_QML_IMPORT_PATH}"
    export QT_PLUGIN_PATH="${qtPluginPath}''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
    exec ${config.programs.hyprland.package}/bin/start-hyprland
  '';

  # providedSessions must name the .desktop file without its extension —
  # services.displayManager.sessionPackages type-checks for that attribute and
  # rejects a plain derivation ("package with provided sessions").
  session = (pkgs.writeTextFile {
    name = "hyprland-ii-session";
    destination = "/share/wayland-sessions/hyprland-ii.desktop";
    text = ''
      [Desktop Entry]
      Name=Hyprland (illogical-impulse)
      Comment=Hyprland with the end-4 / end4-pC dots, from a separate config root
      Exec=${launcher}/bin/start-hyprland-ii
      TryExec=${launcher}/bin/start-hyprland-ii
      Type=Application
      DesktopNames=Hyprland
    '';
  }).overrideAttrs (_: {
    passthru.providedSessions = [ "hyprland-ii" ];
  });
in
{
  # ── The third entry in the greeter.
  #
  # The other two ("Hyprland" and "Hyprland (uwsm-managed)") ship inside the
  # Hyprland package itself; sessionPackages is how a session that isn't part
  # of a package gets listed. defaultSession stays hyprland-uwsm in ./sddm.nix
  # on purpose — if this session fails to come up, the greeter still offers the
  # working one rather than looping on a broken default. SDDM does remember the
  # last session per user, so after picking this one it will be preselected.
  services.displayManager.sessionPackages = [ session ];

  # ── hyprlock.
  #
  # The caelestia session locks with its own QML locker, which points PAM at a
  # config dir inside its package and so never needed an /etc/pam.d entry (see
  # the note in ./hyprland-desktop.nix). ii locks with hyprlock, which does:
  # without this option there is no pam.d/hyprlock and the lock screen refuses
  # every password. Enabling it adds the PAM entry and the binary and changes
  # nothing for session A.
  programs.hyprlock.enable = true;

  # ── Fonts, system-wide rather than in home.packages.
  #
  # This is not a style choice. home-manager makes profile fonts visible by
  # writing ~/.config/fontconfig/conf.d/10-hm-fonts.conf — which lives in
  # ~/.config, the root session B does not read. Fonts installed into the user
  # profile would therefore be invisible in exactly the session that needs
  # them. The system font dir is picked up from /etc/fonts/fonts.conf, which
  # fontconfig reads regardless of XDG_CONFIG_HOME.
  #
  # google-fonts covers three of the four families the QML names — Readex Pro
  # ("reading"), Space Grotesk ("expressive") and Caveat. material-symbols is
  # the icon font. rubik stands in for Google Sans Flex, which is Google's
  # brand font and packaged nowhere; ../home/ii-session.nix patches the QML to
  # ask for it. JetBrainsMono NF is already in ./fonts.nix.
  fonts.packages = with pkgs; [
    google-fonts
    material-symbols
    rubik
  ];

  # gnome-keyring: ii's execs.lua starts the daemon's secrets component, but
  # the PAM half — unlocking the login keyring with the login password — has to
  # be enabled system-wide, and the daemon needs its D-Bus services.
  services.gnome.gnome-keyring.enable = true;

  # The geoclue demo agent, which start_geoclue_agent.sh launches (patched to
  # the store path in ../home/ii-session.nix). The geoclue2 *service* is
  # already on from ./hyprland-desktop.nix; this is only the agent half.
  environment.systemPackages = [ pkgs.geoclue2-with-demo-agent ];
}
