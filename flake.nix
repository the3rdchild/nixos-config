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

    # ── Caelestia, in two halves.
    #
    # The shell is a quickshell app with a real flake: it exports
    # homeManagerModules.default (-> programs.caelestia) and pins its own
    # quickshell, which MUST be the git version — nixpkgs' tagged
    # quickshell is too old to build it.
    caelestia-shell = {
      url = "github:caelestia-dots/shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The dots are plain config files with no flake of their own, so they
    # come in as a bare source tree. home/caelestia.nix derives a patched
    # copy from it — upstream hardcodes a few FHS paths.
    caelestia-dots = {
      url = "github:caelestia-dots/caelestia";
      flake = false;
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
