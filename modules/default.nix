{ config, pkgs, ... }: {
  imports = [
    ./sddm.nix
    ./bootloader.nix
    ./locales.nix
    ./network.nix
    ./audio.nix
    ./bluetooth.nix
    ./graphics.nix
    ./home.nix
    ./package.nix
    ./hyprland-desktop.nix
    ./service.nix
    ./setting.nix
    ./user.nix
    ./docker.nix
    ./filesystems.nix
    ./automount.nix
    ./acer-ec.nix
  ];
}
