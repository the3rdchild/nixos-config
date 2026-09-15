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
  programs.steam.enable = true;

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
    # the file manager caelestia opens (fileExplorer in ../home/caelestia.nix).
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
    dbeaver-bin
    nmap
    picocom
    screen
    openssl
    mission-center
    firefox
    libreoffice-still
  ];

  programs.nix-ld.enable = true;
}
