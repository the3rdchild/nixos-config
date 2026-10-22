{ pkgs, ... }:
{
  users.users.noouoops = {
    isNormalUser = true;
    description = "noouoops";
    # "ydotool" grants /dev/uinput access for the clipboard-type keybind
    # (CTRL+SHIFT+ALT+V); see programs.ydotool in ./hyprland-desktop.nix.
    # "dialout" grants /dev/ttyUSB* and /dev/ttyACM* access, which UGS needs
    # to talk to a GRBL controller.
    extraGroups = [ "networkmanager" "wheel" "video" "i2c" "ydotool" "dialout" ];
    shell = pkgs.fish;
  };
}
