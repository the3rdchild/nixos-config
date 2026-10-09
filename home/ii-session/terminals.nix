# ── Terminals: kitty first, both translucent, both following the palette.
{ ... }: {
  patch = ''
    # ── foot: translucent background.
    #
    # Upstream's foot.ini carries no colour section at all — the palette is
    # replayed as OSC sequences from the wallpaper-generated sequences.txt (see
    # ../shell.nix and the session's own config.fish), so a section appended
    # here collides with nothing. alpha stays in the file because the
    # sequences cannot keep it: their last OSC 11 carries no alpha, and foot
    # answers that by resetting alpha to the *active theme's* value (osc.c,
    # `alpha = term_theme_get(term)->alpha`).
    #
    # Hence both theme sections, not one. [colors] was renamed [colors-dark]
    # in foot 1.26 and warns on every launch; [colors-light] is the theme a
    # SIGUSR2 or color-theme-switch binding lands on, and without alpha there
    # the window would go opaque the moment anything switched it.
    #
    # The blur that makes this look like anything is Hyprland's
    # decoration:blur, not foot's own `blur=yes`: that option needs
    # ext-background-effect-v1, and Hyprland 0.56 does not implement it.
    if grep -qE '^\[colors(2|-dark|-light)?\]' $out/.config/foot/foot.ini; then
      echo "foot.ini: upstream grew a colour section — merge alpha into it" >&2
      exit 1
    fi
    printf '\n[colors-dark]\nalpha=0.85\n\n[colors-light]\nalpha=0.85\n' >> $out/.config/foot/foot.ini

    # ── kitty: the SUPER+T terminal, translucent like foot.
    #
    # Upstream lists foot first in launch_first_available, so with both
    # installed foot always won; kitty moves to the front and foot stays as
    # the fallback. Every other terminal launch in the shell (apps.terminal,
    # fuzzel, kdeglobals) was already `kitty -1`.
    #
    # Opacity goes in kitty.conf, not the generated kitty-theme.conf: that
    # file is rebuilt from a template on every wallpaper change. Unlike foot,
    # kitty keeps background_opacity across the OSC 11 that sequences.txt
    # replays, so one line covers both light and dark. Same 0.85 as foot;
    # the blur behind it is Hyprland's decoration:blur.
    substituteInPlace $out/.config/hypr/hyprland/variables.lua \
      --replace-fail "launch_first_available.sh 'foot' 'kitty -1'" \
                     "launch_first_available.sh 'kitty -1' 'foot'"
    if grep -q '^background_opacity' $out/.config/kitty/kitty.conf; then
      echo "kitty.conf: upstream set background_opacity — merge 0.85 into it" >&2
      exit 1
    fi
    printf '\n# Translucent, like foot.ini (alpha=0.85)\nbackground_opacity 0.85\n' >> $out/.config/kitty/kitty.conf

    # ── Terminal palette: make the generated copies writable.
    #
    # applycolor.sh builds terminal/sequences.txt (and kitty-theme.conf) by
    # `cp`-ing its template into ~/.local/state and then `sed -i`-ing the
    # colours in. The template is in the store, so cp hands the copy its
    # 0444 mode and sed -i keeps it. From the second wallpaper on, the cp
    # fails on the read-only file, the sed finds no placeholders left, and
    # the first palette ever generated is what gets pushed to every /dev/pts
    # and replayed by every new fish — which is why foot never followed a
    # light/dark switch. `-f` removes the stale read-only copy so an existing
    # install heals itself; --no-preserve=mode makes the new one 0644.
    for f in $out/.config/quickshell/*/scripts/colors/applycolor.sh; do
      substituteInPlace "$f" \
        --replace-fail 'cp "$SCRIPT_DIR/terminal/' 'cp -f --no-preserve=mode "$SCRIPT_DIR/terminal/'
      [ "$(grep -c 'cp -f --no-preserve=mode "$SCRIPT_DIR/terminal/' "$f")" = "2" ] || {
        echo "$f: expected two template copies (kitty + sequences)" >&2
        exit 1
      }
    done
  '';
}
