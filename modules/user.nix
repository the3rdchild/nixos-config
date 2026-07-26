{ pkgs, ... }:
{
  users.users.noouoops = {
    isNormalUser = true;
    description = "noouoops";
    extraGroups = [ "networkmanager" "wheel" "video" "i2c" ];
    shell = pkgs.fish;
  };
}
