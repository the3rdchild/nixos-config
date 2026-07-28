{ pkgs, ... }:
{
  users.users.noouoops = {
    isNormalUser = true;
    description = "noouoops";
    # "ydotool" grants /dev/uinput access for the clipboard-type keybind
    # (CTRL+SHIFT+ALT+V); see programs.ydotool in ./hyprland-desktop.nix.
    extraGroups = [ "networkmanager" "wheel" "video" "i2c" "ydotool" ];
    shell = pkgs.fish;
  };
}
