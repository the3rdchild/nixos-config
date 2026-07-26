{ config, inputs, pkgs, ... }:
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
  ];
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    # Automatically backup existing files
    # that Home Manager wants to manage.
    backupFileExtension = "backup";

    extraSpecialArgs = { inherit inputs; };
    users = {
      noouoops = import ../home/default.nix;
    };
  };
}
