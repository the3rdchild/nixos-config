{ config, pkgs, ... }:
{
  boot.loader = {
    systemd-boot.enable = true;
    # Cap the boot menu at 10 NixOS entries. Without this the menu grew to 66
    # generations, pushing the "Windows Boot Manager" entry (autodetected from
    # the shared ESP after the dualboot install) off the bottom of the screen.
    # Only limits what systemd-boot displays — older generations remain in
    # /nix/var/nix/profiles and stay rollback-able from the CLI.
    systemd-boot.configurationLimit = 10;
    efi.canTouchEfiVariables = true;
  };
  boot.kernelPackages = pkgs.linuxPackages_latest;
}
