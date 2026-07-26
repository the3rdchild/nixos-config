{
  description = "noouoops NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    acer-ec = {
      url = "path:/mnt/doc/acer-ec";
      flake = false;
    };

    # GTK4 settings app for Hyprland. Writes only to its own
    # hyprland-gui.conf, which JaKooLit's entrypoint sources.
    hyprmod = {
      url = "github:BlueManCZ/hyprmod";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, home-manager, ... }: {
    nixosConfigurations.noouoops = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit inputs;
      };
      modules = [
        ./configuration.nix
      ];
    };
  };
}
