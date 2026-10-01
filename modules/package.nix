{ inputs, pkgs, ... }:
{
  programs.fish.enable = true;
  programs.hyprland = {
    enable = true;
    package = pkgs.hyprland;

    # Off since the caelestia session was dropped: that session was the only
    # thing that needed graphical-session.target, and the illogical-impulse
    # session deliberately does not run under UWSM (./ii-session.nix says
    # why). All this turns off is programs.uwsm — the uwsm binary and its user
    # units.
    #
    # It does NOT remove the "Hyprland (uwsm-managed)" entry from the greeter,
    # which is the thing worth knowing here: that entry ships inside the
    # Hyprland package and its TryExec is an absolute store path, so it stays
    # listed and resolvable regardless. ./ii-session.nix filters it out of
    # services.displayManager.sessionPackages instead — see the comment there.
    #
    # What this costs, stated plainly: the `uwsm app` transient scopes are
    # gone, so the VS Code memory cap in ../home/app-limits.nix has nothing to
    # attach to. That cap was already inert in this session for the same
    # reason, so nothing that worked today stops working — but putting the
    # session under UWSM is what would bring it back. See docs/uwsm-migration.md.
    withUWSM = false;
  };

  # Feral GameMode — used by Heroic Games Launcher and ProtonPlus (e.g. STRINOVA)
  # via `gamemoderun %command%`. Provides CPU/governor optimizations, GPU
  # performance mode, and D-Bus notifications while a game is running.
  programs.gamemode.enable = true;
  programs.steam.enable = true;
  programs.kdeconnect.enable = true;

  environment.systemPackages = with pkgs; [
    kitty
    git
    fastfetch
    microsoft-edge
    nodejs_22
    obsidian
    # wireguard-ui removed — was a server-side peer manager (overkill for one
    # client tunnel) and its db/ under /etc/wireguard conflicted with wg-quick.
    # The tunnel is now a plain NetworkManager connection, brought up with
    # `nmcli connection up wg0` (this used to name the Plasma network applet
    # as the other option — that plasmoid never ran under Hyprland, and
    # plasma6 is gone from ./service.nix now anyway).
    wireguard-tools # keeps the `wg` CLI for inspecting NM-managed tunnels
    qdirstat

    # Kept deliberately after plasma6 was removed from ./service.nix — this is
    # the file manager the session opens for SUPER+E and for every "show in
    # folder" action that goes through org.freedesktop.FileManager1.
    # It stands alone fine: its own closure already carries breeze-icons,
    # kiconthemes, kio-extras and qtsvg, so no Plasma session is involved.
    kdePackages.dolphin
    obs-studio
    vscode
    localsend
    # onboard
    dbeaver-bin
    flashprint

    # Disk / EFI tooling kept around after the Windows dual-boot GPT repair
    # (docs recovery guide, commit f2c9cf6).
    efibootmgr
    gparted
    gptfdisk

    # Windows-apps-in-a-container front end (Electron based — see
    # nixpkgs.config.permittedInsecurePackages in modules/setting.nix).
    # winboat
    gcc
    gnumake
    cmake
    ccache # optional; speeds up rebuilds
    pkg-config
    python3
    ethtool
    bun
    pnpm
    uv
    dbeaver-bin
    nmap
    picocom
    screen
    openssl
    mission-center
    firefox
    # The qt6 build, not plain libreoffice-still: that one ships only
    # libvclplug_genlo.so and libvclplug_gtk3lo.so, so LibreOffice rendered as
    # a GTK3 app and never looked at kdeglobals. This variant adds
    # libvclplug_kf6lo.so, which reads the same Breeze colour scheme
    # ../home/qt.nix keeps in step with the session mode — so LibreOffice
    # follows dark/light through the machinery that is already there, rather
    # than through the GTK stack.
    libreoffice-qt6-still
    zip # Flutter prerequisite on Linux
  ];

  # LibreOffice picks its VCL backend from XDG_CURRENT_DESKTOP, and that is
  # "Hyprland" here — not a name it recognises as KDE, so its own fallback
  # order lands on gtk3 even with the kf6 plugin present. This forces it.
  #
  # The variable is LibreOffice-specific, so session-wide scope costs nothing.
  # It must stay in step with the package above: point it at kf6 with a build
  # that lacks the plugin and LibreOffice drops to the bare `gen` backend.
  environment.sessionVariables.SAL_USE_VCLPLUGIN = "kf6";

  programs.nix-ld.enable = true;

  # Flutter / Android builds. Flutter SDK comes from the VS Code extension and
  # the Android SDK lives writable in ~/Android/Sdk (Gradle downloads NDK and
  # build-tools into it); both run through nix-ld above. Only the JDK is from
  # nixpkgs — this also exports JAVA_HOME. zip is on Flutter's Linux
  # prerequisite list; curl and unzip are already present.
  programs.java = {
    enable = true;
    package = pkgs.jdk17;
  };

  # The SDK is the stable release tarball unpacked to ~/flutter-sdk — one of
  # the paths the Dart-Code extension probes on its own. Its `git clone` of
  # the full history kept dropping mid-fetch. PATH makes flutter/dart usable
  # from a terminal too; ANDROID_HOME points Gradle and `flutter doctor` at
  # the writable SDK.
  environment.sessionVariables.ANDROID_HOME = "$HOME/Android/Sdk";
  # No Chrome on this machine; Flutter's web target drives any Chromium, and
  # Edge (above) is one.
  environment.sessionVariables.CHROME_EXECUTABLE = "${pkgs.microsoft-edge}/bin/microsoft-edge";
  environment.extraInit = ''
    export PATH="$HOME/flutter-sdk/bin:$PATH"
  '';
}
