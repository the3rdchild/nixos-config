{
  description = "noouoops NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # No acer-ec input: the driver tree is in-repo at
    # Reference/acer-aspire-A715-79G/acer-ec and modules/acer-ec.nix reaches it
    # by relative path. See the comment there.

    # ── Caelestia, in two halves.
    #
    # The shell is a quickshell app with a real flake: it exports
    # homeManagerModules.default (-> programs.caelestia) and pins its own
    # quickshell, which MUST be the git version — nixpkgs' tagged
    # quickshell is too old to build it.
    #
    # Pinned to a release tag, not `main`. home/caelestia.nix patches five
    # upstream files with --replace-fail anchors and adds a nexus Display page
    # written against upstream's own row components, so every bump has to be
    # read before it is taken — a tag is a thing you can diff against, a moving
    # branch is not. Reference/release holds the extracted tree of the pinned
    # tag (REVISION matches the rev below) for exactly that check.
    #
    # The tag string here is also what nexus → About reports: home/caelestia.nix
    # reads `ref` back out of flake.lock to override upstream's hardcoded
    # `version = "1.0.0"` placeholder. Changing this line and re-locking is
    # enough; there is no second copy of the version to keep in sync.
    caelestia-shell = {
      url = "github:caelestia-dots/shell/v2.3.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The dots are plain config files with no flake of their own, so they
    # come in as a bare source tree. home/caelestia.nix derives a patched
    # copy from it — upstream hardcodes a few FHS paths.
    caelestia-dots = {
      url = "github:caelestia-dots/caelestia";
      flake = false;
    };

    # ── HyprMod, the GTK4 settings GUI for the compositor.
    #
    # Not in nixpkgs. The flake exports packages.default and its derivation
    # wraps lua5_4 onto PATH, which its config reader needs to execute a
    # Lua-mode config.
    #
    # Pinned by rev rather than tag on purpose: the Nix packaging landed
    # AFTER the v0.4.0 tag — nix/hyprmod.nix and flake.nix don't exist at
    # v0.4.0 at all — so there is no tag that can be built. A rev is still a
    # thing you can diff against; re-pin it when bumping rather than letting
    # `main` float, because the one thing that matters here (first-run setup
    # wanting to write to hyprland.lua — see hypr-user.lua in
    # home/caelestia.nix) is upstream behaviour that could change silently.
    hyprmod = {
      url = "github:BlueManCZ/hyprmod/c1edad16510538190f65cde0f27fc2825045ce04";
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
