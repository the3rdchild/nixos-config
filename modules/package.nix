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
  programs.gamemode = {
    enable = true;
    enableRenice = true; # allow gamemode to lower niceness (needs CAP_SYS_NICE)
  };

  environment.systemPackages = with pkgs; [
    kitty
    hyprland
    git
    fastfetch
    wget
    dpkg
    microsoft-edge
    firefox
    nodejs_22
    python312
    obsidian
    discord
    steam
    # wireguard-ui removed — was a server-side peer manager (overkill for one
    # client tunnel) and its db/ under /etc/wireguard conflicted with wg-quick.
    # The tunnel is now a plain NetworkManager connection, toggled from the
    # Plasma network applet or `nmcli connection up wg0`.
    wireguard-tools # keeps the `wg` CLI for inspecting NM-managed tunnels
    flatpak
    qdirstat
    cameractrls
    obs-studio
    vscode
    localsend
    fanctl
    cloudflare-warp
    onboard
    dbeaver-bin
    gamemode
  ];

  programs.nix-ld.enable = true;
}
