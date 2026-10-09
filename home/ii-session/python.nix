# ── The Python "venv".
#
# Upstream expects ILLOGICAL_IMPULSE_VIRTUAL_ENV to point at a real uv-built
# venv in ~/.local/state and activates it in nine places — six shell
# wrappers plus three scripts whose shebang is
#   #!/usr/bin/env -S _/bin/sh_-c_"source_$(eval echo $I_I_VIRTUAL_ENV)/bin/activate&&exec_python_-E_..."
# Rather than patch nine call sites, this builds the interpreter with Nix and
# fakes the one file they all reach for: bin/activate. Sourcing it puts the
# store env on PATH, which is all those call sites actually want.
#
# `python -E` in that shebang is the reason this needs checking rather than
# assuming: -E makes CPython ignore PYTHONPATH. nixpkgs' python doesn't use
# PYTHONPATH — withPackages resolves imports through the env's own prefix —
# so -E is harmless here. Verified before this file was written.
{ pkgs, ... }: let
  # Upstream's sdata/uv/requirements.in minus the build-time-only entries
  # (build, wheel, setuptools-scm), which nothing imports at runtime.
  pythonEnv = pkgs.python3.withPackages (ps:
    with ps; [
      # Actually imported by scripts in both trees.
      materialyoucolor # 32 imports — the colour engine
      numpy
      opencv4 # cv2, used by find_regions / least-busy-region
      pygobject3 # gi
      pillow # PIL
      tqdm
      loguru
      click
      # Invoked as a command by matugen/templates/kde/*-wrapper.sh.
      kde-material-you-colors
      # Used by services/gCloud/token-from-key-venv.sh.
      google-auth
      requests
      # Upstream ships these; cheap, and kept so a script that grows a new
      # import doesn't fail at runtime in a session with no terminal attached.
      psutil
      pycairo
      libsass
      material-color-utilities
      setproctitle
      pywayland
    ]);
in rec {
  venv = pkgs.runCommand "illogical-impulse-venv" { } ''
    mkdir -p $out/bin
    ln -s ${pythonEnv}/bin/* $out/bin/

    # Sourced, never executed — so no shebang, and it must be valid in both
    # bash and sh. Mirrors what a real venv's activate does, minus the prompt
    # mangling and the pyvenv.cfg lookup.
    cat > $out/bin/activate <<'ACTIVATE'
VIRTUAL_ENV="@venv@"
export VIRTUAL_ENV
_OLD_VIRTUAL_PATH="$PATH"
PATH="@python@/bin:$PATH"
export PATH
deactivate() {
    if [ -n "''${_OLD_VIRTUAL_PATH:-}" ]; then
        PATH="$_OLD_VIRTUAL_PATH"
        export PATH
        unset _OLD_VIRTUAL_PATH
    fi
    unset VIRTUAL_ENV
    unset -f deactivate
}
ACTIVATE
    substituteInPlace $out/bin/activate \
      --replace-fail '@venv@' "$out" \
      --replace-fail '@python@' '${pythonEnv}'
  '';

  patch = ''
    sed -i 's|home_dir \.\. "/.local/state/quickshell/.venv"|"${venv}"|' \
      $out/.config/hypr/hyprland/env.lua
    grep -q '${venv}' $out/.config/hypr/hyprland/env.lua
  '';
}
