{ inputs, pkgs, ... }:
{
  programs.fish.enable = true;
  programs.hyprland = {
    enable = true;
    package = pkgs.hyprland;
  };

  # Feral GameMode — used by Heroic Games Launcher and ProtonPlus (e.g. STRINOVA)
  # via `gamemoderun %command%`. Provides CPU/governor optimizations, GPU
  # performance mode, and D-Bus notifications while a game is running.
  programs.gamemode.enable = true;

  environment.systemPackages = with pkgs; [
    kitty
    hyprland
    git
    fastfetch
    wget
    dpkg
    microsoft-edge
    # firefox
    nodejs_22
    python312
    obsidian
    # discord
    steam
    # wireguard-ui removed — was a server-side peer manager (overkill for one
    # client tunnel) and its db/ under /etc/wireguard conflicted with wg-quick.
    # The tunnel is now a plain NetworkManager connection, brought up with
    # `nmcli connection up wg0` (this used to name the Plasma network applet
    # as the other option — that plasmoid never ran under Hyprland, and
    # plasma6 is gone from ./service.nix now anyway).
    wireguard-tools # keeps the `wg` CLI for inspecting NM-managed tunnels
    qdirstat

    # Kept deliberately after plasma6 was removed from ./service.nix — this is
    # the file manager caelestia opens (fileExplorer in ../home/caelestia.nix).
    # It stands alone fine: its own closure already carries breeze-icons,
    # kiconthemes, kio-extras and qtsvg, so no Plasma session is involved.
    kdePackages.dolphin
    cameractrls
    obs-studio
    vscode
    localsend
    fanctl
    cloudflare-warp
    # onboard
    dbeaver-bin
    gamemode
    flashprint
    # Proton/Wine prefix management for Steam games (e.g. STRINOVA launcher
    # needs WebView2 pre-installed via `protontricks 1282270 webview2` because
    # the launcher's built-in DXWSetup fails under Wine — see memory note
    # strinova-proton-fix-v2.md Issue 5).
    protontricks
    winetricks

    # Disk / EFI tooling kept around after the Windows dual-boot GPT repair
    # (docs recovery guide, commit f2c9cf6).
    efibootmgr
    parted
    gparted
    gptfdisk

    # Windows-apps-in-a-container front end (Electron based — see
    # nixpkgs.config.permittedInsecurePackages in modules/setting.nix).
    # winboat

    # OpenPLC Runtime build dependencies (docs/NIXOS.md step 1). install.sh
    # has no NixOS branch, so the toolchain is declared here. gcc/cmake/etc.
    # are also the source of the nix-store lib paths that scripts/nixos-env.sh
    # derives at run time (libstdc++.so.6, python3-embed.pc, libpython).
    gcc
    gnumake
    cmake
    ccache # optional; speeds up rebuilds
    pkg-config
    python3
    ethtool
    bun
    python314Packages.pip
    dbeaver-bin
    nmap
    picocom
    screen
    tailscale
    openssl
    mission-center
  ];

  programs.nix-ld.enable = true;
}
