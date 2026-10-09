# ── MicroTeX, the LaTeX renderer.
#
# Both shells render $$...$$ in an AI reply by shelling out to
# `cd <microtexBinaryDir> && ./LaTeX -headless -input=... -output=<x>.svg`
# (services/LatexRenderer.qml:24,60). The `cd` is not incidental: the binary
# resolves its font metrics through tex::RES_BASE, which is the literal
# relative string "res" (src/latex.cpp:14) and which the sample's CLI does
# not expose — so the binary and its res/ tree have to sit in one directory
# and that directory has to be the working directory. Hence the /opt-shaped
# layout below: it is the one thing the QML already knows how to use, and
# the patch only has to move the path, not the mechanism.
#
# Not in home.packages: nothing runs it from PATH. The patched QML's
# reference to the store path is what keeps it alive.
{ pkgs, inputs, ... }: rec {
  # The build is upstream's own PKGBUILD minus its two seds. Its
  # tinyxml2.so.10 -> .11 rewrite is against a hardcoded soname this rev no
  # longer has, and its gtksourceviewmm-3.0 -> 4.0 rewrite exists because Arch
  # dropped the gtkmm3-era bindings; nixpkgs still ships them, so applying it
  # would be the thing that breaks the build rather than fixes it.
  #
  # gtksourceview3 alongside gtksourceviewmm: the C++ bindings' .pc file
  # Requires: the C library's, and pkg-config fails the whole lookup — with
  # "Package 'gtksourceview-3.0' ... not found", not a missing-header error —
  # if only the bindings are present.
  microtex = pkgs.stdenv.mkDerivation {
    pname = "microtex";
    version = "0-unstable-2026-06-05";
    src = inputs.microtex;

    nativeBuildInputs = with pkgs; [ cmake pkg-config ];
    buildInputs = with pkgs; [
      tinyxml-2
      gtkmm3
      gtksourceviewmm
      gtksourceview3
      cairomm
      fontconfig
    ];

    # No install rules in CMakeLists at all — the PKGBUILD copies the two
    # artefacts out of the build tree by hand, and so does this. cmake's
    # configure step is what puts res/ next to the binary (`file(COPY res
    # DESTINATION .)`, CMakeLists.txt:49), so both live in the build dir,
    # which is where installPhase runs.
    installPhase = ''
      runHook preInstall
      install -Dm0755 LaTeX $out/opt/MicroTeX/LaTeX
      cp -r res $out/opt/MicroTeX/res
      runHook postInstall
    '';

    # The one thing worth checking is the mode the shells actually use, since
    # a GUI-only build would still install cleanly and fail at runtime with
    # nothing on screen.
    doInstallCheck = true;
    installCheckPhase = ''
      cd $out/opt/MicroTeX
      ./LaTeX -headless '-input=\frac{a}{b}' -output=$TMPDIR/check.svg \
        -textsize=16 -padding=4 -maxwidth=0.85
      grep -q "<svg" $TMPDIR/check.svg
    '';

    meta = {
      description = "LaTeX rendering engine used by the illogical-impulse shells";
      homepage = "https://github.com/end-4/MicroTeX";
      license = pkgs.lib.licenses.mit;
      mainProgram = "LaTeX";
    };
  };

  # Both shells hardcode /opt/MicroTeX and then `cd` into it, so the store
  # path replaces the whole directory and the `cd` still works. Counted
  # rather than globbed blindly: this is a silent failure if it misses,
  # because a missing renderer shows up as an AI reply with a blank where the
  # formula should be, and nothing in any log.
  patch = ''
    latexRenderers=$(grep -rIl 'microtexBinaryDir' $out/.config/quickshell | wc -l)
    [ "$latexRenderers" = "2" ] || {
      echo "LatexRenderer.qml: expected one per shell, found $latexRenderers" >&2
      exit 1
    }
    grep -rIlZ '"/opt/MicroTeX"' $out/.config/quickshell \
      | xargs -0 -r sed -i 's|"/opt/MicroTeX"|"${microtex}/opt/MicroTeX"|'
    [ "$(grep -rIo '${microtex}/opt/MicroTeX' $out/.config/quickshell | wc -l)" = "2" ] || exit 1
  '';
}
