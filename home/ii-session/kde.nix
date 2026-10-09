# ── The KDE pieces the shell leans on without running Plasma.
{ pkgs, lib, ... }: {
  # ── The two plasma-workspace tools the colour pipeline shells out to.
  #
  # kde-material-you-colors is the Qt half of that pipeline: matugen/templates/
  # kde/kde-material-you-colors-wrapper.sh runs it on every wallpaper change,
  # it writes .colors files into ~/.local/share/color-schemes, and then calls
  # `plasma-apply-colorscheme` to apply one and `plasma-changeicons` to set the
  # icon theme (plasma_utils.py:89-96). Both live only in
  # kdePackages.plasma-workspace, and a missing one is exit 127 with the
  # generation half still succeeding — which reads on screen as "the Qt apps
  # ignored the wallpaper".
  #
  # plasma-workspace is already in the system closure (`nix why-depends
  # /run/current-system <plasma-workspace>` walks system-path ->
  # xdg-desktop-portal-kde -> plasma-workspace), so this costs zero new store
  # paths. Measured, not assumed: 0 of its 607 closure paths are absent from
  # the running system.
  #
  # Symlinks rather than home.packages = [ plasma-workspace ], because what is
  # NOT wanted is the rest of it — 25 binaries including plasmashell and
  # startplasma-wayland on PATH, its .desktop entries in the launcher, and its
  # 8 D-Bus activation services becoming reachable through the profile's
  # share/dbus-1 (the profile IS in XDG_DATA_DIRS). The systemd units and the
  # four XDG autostart entries are inert either way — the units are WantedBy
  # plasma targets a Hyprland session never reaches, and the autostart files
  # are all OnlyShowIn=KDE.
  #
  # A symlink is enough for both: Qt resolves applicationDirPath through
  # /proc/self/exe, which follows it back to the real store path, so neither
  # binary loses track of its own resources. Verified by running both through
  # one.
  #
  # plasma-changeicons comes out of libexec/, not bin/ — it is a helper
  # upstream never meant to be called by hand, and kde-material-you-colors
  # calls it by bare name off PATH anyway.
  plasmaTools = pkgs.runCommand "ii-plasma-tools" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.kdePackages.plasma-workspace}/bin/plasma-apply-colorscheme $out/bin/
    ln -s ${pkgs.kdePackages.plasma-workspace}/libexec/plasma-changeicons $out/bin/
  '';

  # ── kcmshell6 and systemsettings, able to load the Bluetooth and Network KCMs.
  #
  # Both KCMs installed fine and still failed at load, each for a reason the
  # nixpkgs Plasma module would have hidden and this session does not:
  #
  #   kcm_bluetooth          main.qml:22 imports org.kde.bluezqt, which lives
  #                          in bluez-qt. bluedevil links the C++ library but
  #                          propagates nothing, so no QML path held it —
  #                          "module org.kde.bluezqt is not installed".
  #   kcm_networkmanagement  a QWidgets KCM that finds its main.qml through
  #                          XDG_DATA_DIRS (share/kcm_networkmanagement/qml).
  #                          The per-user profile only links the share/ subdirs
  #                          listed in environment.pathsToLink, and Plasma's
  #                          module is what normally widens that to all of
  #                          /share. Not found means an empty QQuickWidget: a
  #                          fully transparent window and no error at all.
  #                          Once found, its ConnectionItem.qml needs
  #                          org.kde.plasma.components (libplasma), which in
  #                          turn needs org.kde.ksvg.
  #
  # Wrapped here rather than put on the session's QML path in
  # ../../modules/ii-session.nix, so libplasma never lands on quickshell's
  # import path. Verified by running both KCMs with exactly these additions:
  # no QML errors, and both render.
  kcmHosts = pkgs.symlinkJoin {
    name = "ii-kcm-hosts";
    paths = [ pkgs.kdePackages.kcmutils pkgs.kdePackages.systemsettings ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      for b in kcmshell6 systemsettings; do
        wrapProgram $out/bin/$b \
          --prefix NIXPKGS_QT6_QML_IMPORT_PATH : ${lib.concatMapStringsSep ":" (p: "${p}/lib/qt-6/qml") [
            pkgs.kdePackages.bluez-qt
            pkgs.kdePackages.libplasma
            pkgs.kdePackages.ksvg
          ]} \
          --prefix XDG_DATA_DIRS : ${pkgs.kdePackages.plasma-nm}/share
      done
    '';
  };

  # ── Icon theme, for the half of the colour pipeline that never ran.
  #
  # kde-material-you-colors switches the icon theme with the light/dark mode
  # too, via plasma-changeicons (see plasmaTools above). The themes upstream
  # names here are breeze-plus / breeze-plus-dark, which is the one
  # dependency still packaged nowhere, so the call would find its tool and
  # then fail on a missing theme. breeze and breeze-dark ship in
  # kdePackages.breeze-icons, already in ./packages.nix, and are what
  # breeze-plus forks anyway.
  #
  # This is the seed only. config.conf is in mutablePaths, so an install
  # that already has one keeps it — the live file has to be edited by hand,
  # which is the same bargain every other entry in that list makes.
  patch = ''
    substituteInPlace $out/.config/kde-material-you-colors/config.conf \
      --replace-fail 'iconslight = breeze-plus' 'iconslight = breeze' \
      --replace-fail 'iconsdark = breeze-plus-dark' 'iconsdark = breeze-dark'
  '';
}
