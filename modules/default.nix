{ config, pkgs, ... }: {
  imports = [
    ./sddm.nix
    ./bootloader.nix
    ./locales.nix
    ./fonts.nix
    ./network.nix
    ./audio.nix
    ./bluetooth.nix
    ./graphics.nix
    ./home.nix
    ./package.nix
    ./hyprland-desktop.nix
    ./service.nix
    ./setting.nix
    ./power.nix
    ./user.nix
    ./docker.nix
    ./filesystems.nix
    ./automount.nix
    ./acer-ec.nix
    ./openplc.nix
  ];
}
