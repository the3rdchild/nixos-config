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

    # ── quickshell, the runtime the session B shells are written against.
    #
    # `qs` — the binary ii and end4-pC actually run. It used to arrive as a
    # transitive input of the caelestia shell's flake, which is why dropping
    # that session could not simply delete it: session B was running
    # caelestia's quickshell all along. This is the same rev that input
    # resolved to (0.3.1), so the store path is unchanged by the move.
    #
    # git.outfoxxed.me, not the GitHub mirror, because that is where the rev
    # was locked from and re-pointing it would relock to a different node for
    # the same commit. nixpkgs' tagged quickshell is 0.3.0 and is NOT a
    # substitute: these dots are verified against 0.3.1 only.
    #
    # Deliberately NOT the rev end-4's own sdata/dist-nix pins
    # (7511545e, 2026-03-19). That is six months older than this, and the
    # session has only ever been run on 0.3.1.
    quickshell = {
      url = "git+https://git.outfoxxed.me/outfoxxed/quickshell?ref=refs/heads/master&rev=0fed22a2c47d9568ddf13cf61586b3f2ac4378a2";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ── illogical-impulse (end-4) + the end4-pC fork, for the second session.
    #
    # Two halves again, and neither has a flake: both are plain config trees
    # that ../home/ii-session.nix patches into a single derivation. They only
    # ever feed session B ("Hyprland (illogical-impulse)"), which since the
    # caelestia session was dropped is the only session there is.
    #
    # type = "git" + submodules = 1, NOT the shorter github: form. The tree
    # carries one submodule — dots/.config/quickshell/ii/modules/common/
    # widgets/shapes -> rounded-polygon-qmljs — and github: tarballs never
    # include submodules. QML imports it by relative path
    # (widgets/MaterialCookie.qml:8), so without it MaterialCookie,
    # MaterialShape and MaterialLoadingIndicator fail to load at runtime with
    # nothing in the logs but a missing-import warning.
    #
    # Pinned by rev, not a tag: the repo's tags are date stamps on a fast
    # branch, and the rev below is what Reference/dots-hyprland has checked
    # out, so the tree on disk is the tree that gets built.
    dots-hyprland = {
      url = "git+https://github.com/end-4/dots-hyprland?ref=main&rev=2f0c8bf42b803f4d597572f2a014d4e78d7d9f26&submodules=1";
      flake = false;
    };

    # The fork. Despite "requires illogical-impulse" in its README this is not
    # an overlay — it is a complete quickshell config root (shell.qml,
    # modules/, services/) that installs alongside ii rather than over it, so
    # both land in .config-ii/quickshell/ and `qs -c ii` / `qs -c end4-pC`
    # switches between them without a rebuild. What it needs from ii is the
    # rest of the install: the hypr Lua config, the Python venv, the matugen
    # templates and the fonts.
    #
    # No tags at all upstream, so a rev is the only thing to pin to.
    end4-pc = {
      url = "github:pctrade/end4-pC/da31320c85500eb130b0011474c917751d41b29a";
      flake = false;
    };

    # ── MicroTeX, the LaTeX renderer the AI chat shells out to.
    #
    # Not in nixpkgs, and not upstream's MicroTeX either: both shells run
    # `cd <dir> && ./LaTeX -headless`, and the `LaTeX` binary with that CLI is
    # end-4's fork (NanoMichael's tree has no -headless sample). ../home/
    # ii-session.nix builds it and rewrites the hardcoded /opt/MicroTeX in
    # LatexRenderer.qml to the store path; without it every $$...$$ in an AI
    # reply renders as nothing at all, silently.
    #
    # No tags upstream, so a rev — same as end4-pc above. The
    # build follows upstream's own Arch PKGBUILD (sdata/dist-arch/
    # illogical-impulse-microtex-git) except for its two seds: this rev already
    # carries the tinyxml2 soname fix, and nixpkgs still has gtksourceviewmm 3,
    # so the gtksourceviewmm-4.0 rewrite Arch needs would only break it here.
    microtex = {
      url = "github:end-4/MicroTeX/e8c6e58b1306119e51297b02f0b449fa7300416d";
      flake = false;
    };

    # ── SilentSDDM, the login screen theme.
    #
    # Not in nixpkgs. The flake exports nixosModules.default
    # (-> programs.silentSDDM), which builds the theme with the chosen preset,
    # settings overrides and extra backgrounds baked into the store path.
    # Pinned to a release tag rather than a branch: the
    # module forces sddm options (theme, wayland.enable, GreeterEnvironment)
    # that modules/sddm.nix has to agree with, so bumps should be read first.
    silent-sddm = {
      url = "github:uiriansan/SilentSDDM/v1.5.0";
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
