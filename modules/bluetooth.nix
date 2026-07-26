{ config, pkgs, ... }:
{
  # Intel AX210NGW — Wi-Fi 6E / Bluetooth 5.3 combo card.
  # BT side is driven by btusb + btintel; firmware intel/ibt-0041-0041.sfi
  # ships in linux-firmware and is already loading on this machine.
  hardware.enableRedistributableFirmware = true;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        # Needed for LE audio / headset battery reporting
        Experimental = true;
        FastConnectable = true;
      };
      Policy = {
        AutoEnable = true;
      };
    };
  };

  # GUI pairing applet for Hyprland (Plasma 6 already ships bluedevil)
  services.blueman.enable = true;

  environment.systemPackages = with pkgs; [
    bluez        # bluetoothctl, btmgmt
    bluez-tools  # bt-adapter, bt-device
  ];
}
