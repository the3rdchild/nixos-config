# Rofi theme collection from github.com/newmanls/rofi-themes-collection.
#
# What this installs:
#   Every .rasi theme in the upstream `themes/` directory (rounded-* family,
#   squared-*, spotlight, launchpad, windows11-*, simple-tokyonight, …) is
#   symlinked into ~/.local/share/rofi/themes/ — the standard directory rofi
#   scans for user themes. The `template/` subdirectory is included too,
#   because the `rounded-*` themes do `@import "template/rounded-template.rasi"`
#   and would fail to render without it.
#
# How to use:
#   Open rofi's theme picker (`rofi-theme-selector`) — all upstream themes
#   will now appear. Or set one declaratively (see `home/themes.nix` for the
#   GTK/icon/cursor registry; the rofi `@theme` line is intentionally left
#   for the JaKooLit dots' `config.rasi` to manage, since it lives in a file
#   those dots own).
#
# Reproducibility:
#   The upstream repo is fetched via fetchFromGitHub with a pinned rev and
#   sha256. To bump: change `rev` to the new commit, leave `hash` as
#   lib.fakeSha256, rebuild, copy the "got: sha256-…" line Nix prints, and
#   paste it back as `hash`.
{ config, pkgs, lib, ... }:
let
  rofiThemesSrc = pkgs.fetchFromGitHub {
    owner = "newmanls";
    repo = "rofi-themes-collection";
    rev = "911cc27afe9c66d7e2cb06a47c905d046ea3dfd2";  # master, Jul 2026
    hash = "sha256-YdsuzmpU/fokvF1/vKuiK/eOLFGfhJcFu8HvUIqx9Ao=";
  };

  # A derivation that lays out the themes the way rofi expects them on disk:
  #   $out/share/rofi/themes/<theme>.rasi
  #   $out/share/rofi/themes/template/...
  # We mirror the upstream `themes/` layout under share/rofi/themes/ so the
  # @import "template/rounded-template.rasi" lines resolve correctly.
  rofiThemesPkg = pkgs.stdenvNoCC.mkDerivation {
    pname = "rofi-themes-collection";
    version = "unstable-2026-07";
    src = rofiThemesSrc;

    dontBuild = true;
    dontConfigure = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/share/rofi/themes
      # Copy every .rasi + the template dir verbatim.
      cp -r themes/. $out/share/rofi/themes/
      runHook postInstall
    '';

    meta = with lib; {
      description = "Themes collection for rofi launcher (newmanls fork)";
      homepage = "https://github.com/newmanls/rofi-themes-collection";
      license = licenses.gpl3Plus;
      platforms = platforms.all;
    };
  };
in
{
  # Expose all themes via the XDG user-data dir: ~/.local/share/rofi/themes/
  #
  # rofi scans ~/.local/share/rofi/themes/ FLAT (one level — it does NOT
  # recurse into subdirectories). So each .rasi must sit directly in that
  # folder, and the `template/` subdir must also be at that level for the
  # `@import "template/rounded-template.rasi"` lines inside the rounded-*
  # themes to resolve. We therefore mirror the upstream layout file-by-file
  # rather than dropping the collection under one extra subdir.
  xdg.dataFile =
    let
      # List everything under themes/ in the nix store path. We keep both
      # regular files (*.rasi) and the template/ directory.
      themesDir = "${rofiThemesPkg}/share/rofi/themes";
    in
    {
      # Ensure ~/.local/share/rofi/themes/ exists even on a fresh home.
      "rofi/themes/.keep".text = "";

      # `xdg.dataFile` doesn't do recursive globs; instead we point each
      # path at its store location. Since we don't know the file list at
      # evaluation time without a readDir, we ship the whole themesDir as
      # a single recursive entry that places contents directly in the
      # target. (recursive=true means the *contents* of the source dir are
      # linked into the target, not the dir itself.)
      "rofi/themes" = {
        source = themesDir;
        recursive = true;
      };
    };

  # Document where the themes came from in the system packages list, mainly so
  # `nix why-depends` / `nix-store -qR` trace makes sense if someone wonders.
  home.packages = [ rofiThemesPkg ];
}
