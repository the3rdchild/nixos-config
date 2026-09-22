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
      url = "github:caelestia-dots/shell/v2.4.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The dots are plain config files with no flake of their own, so they
    # come in as a bare source tree. home/caelestia.nix derives a patched
    # copy from it — upstream hardcodes a few FHS paths.
    caelestia-dots = {
      url = "github:caelestia-dots/caelestia";
      flake = false;
    };

    # ── illogical-impulse (end-4) + the end4-pC fork, for the second session.
    #
    # Two halves again, and neither has a flake: both are plain config trees
    # that ../home/ii-session.nix patches into a single derivation. They only
    # ever feed session B ("Hyprland (illogical-impulse)"); nothing here
    # touches the caelestia session.
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
    # No tags at all upstream, so a rev is the only thing to pin to — same
    # situation as hyprmod below.
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
    # No tags upstream, so a rev — same as end4-pc and hyprmod above. The
    # build follows upstream's own Arch PKGBUILD (sdata/dist-arch/
    # illogical-impulse-microtex-git) except for its two seds: this rev already
    # carries the tinyxml2 soname fix, and nixpkgs still has gtksourceviewmm 3,
    # so the gtksourceviewmm-4.0 rewrite Arch needs would only break it here.
    microtex = {
      url = "github:end-4/MicroTeX/e8c6e58b1306119e51297b02f0b449fa7300416d";
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

    # ── SilentSDDM, the login screen theme.
    #
    # Not in nixpkgs. The flake exports nixosModules.default
    # (-> programs.silentSDDM), which builds the theme with the chosen preset,
    # settings overrides and extra backgrounds baked into the store path.
    # Pinned to a release tag for the same reason as caelestia-shell: the
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
