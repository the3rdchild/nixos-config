# ── Light/dark follows the wallpaper.
#
# These dots never look at the wallpaper to decide light or dark. The mode
# comes from gsettings and nothing else (switchwall.sh, the
# `if [[ -z "$mode_flag" ]]` branch), which is why a white wallpaper still
# renders a dark palette — matugen is handed --mode dark and derives a dark
# scheme from that image's hues. Picking an accent colour does not change it
# either; --color only passes the colour through to matugen.
#
# This replaces that branch. The decision still lands in the same variable,
# so it flows on into `pre_process "$mode_flag"` further down, which is what
# writes org.gnome.desktop.interface color-scheme and gtk-theme — so the
# portal, GTK and Qt all follow without any extra plumbing.
#
# On by default, off by one command, because a luminance threshold is always
# wrong for some images and you will want to override it. An explicit
# --mode still wins: the Settings light/dark buttons keep working as a
# one-off, and the next wallpaper change re-derives.
{ pkgs, lib, qsConfig, fill, videoFrame, ... }: let
  # Calibrated against the torii pair, which is the reference: "torii dark"
  # measures 0.541 and "torii white" 0.907, so anything in (0.541, 0.907] sorts
  # them correctly. 0.6 is the low end of that window on purpose — it is the
  # smallest move from a neutral 0.5 that satisfies the constraint, so it
  # reclassifies torii dark and nothing else in the current set:
  #
  #   wallhaven-vg8y8m  0.051  dark
  #   Cyrene            0.158  dark
  #   torii dark        0.541  dark   <- the one this threshold exists for
  #   Kokomi            0.692  light
  #   wallhaven-exmppk  0.772  light
  #   Escoffier         0.792  light
  #   torii white       0.907  light
  #
  # Raising it further (0.72 would also make Kokomi dark) is a taste call, not
  # a correctness one — this single value is the only thing to edit.
  threshold = "0.6";

  # Prints the mode for an image (or the configured wallpaper), given the
  # --mode the caller asked for. A video is measured by its still frame, the
  # same one its palette comes from.
  autoLightDark = pkgs.writeShellScript "ii-auto-lightdark" (fill ./files/auto-lightdark.sh {
    path = lib.makeBinPath [ pkgs.imagemagick pkgs.gawk pkgs.coreutils ];
    dconf = pkgs.dconf;
    jq = pkgs.jq;
    inherit videoFrame threshold;
  });
in {
  # `ii-lightdark-auto [status|on|off|toggle]`
  autoLightDarkCtl = pkgs.writeShellScriptBin "ii-lightdark-auto" (fill ./files/lightdark-auto.sh {
    path = lib.makeBinPath [ pkgs.jq pkgs.coreutils ];
    inherit qsConfig;
  });

  patch = ''
    # Applied to both shells: each carries its own copy of switchwall.sh.
    for f in $out/.config/quickshell/*/scripts/colors/switchwall.sh; do
      [ -e "$f" ] || continue
      # Inserted before upstream's own block rather than replacing it: with
      # auto off the helper echoes $mode_flag back unchanged and the original
      # precedence below runs exactly as written.
      substituteInPlace "$f" --replace-fail \
        'if [[ -z "$mode_flag" ]]; then' \
        'mode_flag="$(${autoLightDark} "$imgpath" "$mode_flag")"
            if [[ -z "$mode_flag" ]]; then'

      # ── And the write that decision turns into: dconf, not gsettings.
      #
      # pre_process() is the only thing that tells the rest of the machine
      # what mode this wallpaper chose — the portal, GTK and Qt all read
      # org.gnome.desktop.interface color-scheme and nothing else. It spelled
      # that write as `gsettings set`, which on a session with no schemas on
      # XDG_DATA_DIRS exits 1 and prints "No schemas installed" to a stderr
      # nobody reads. ../../modules/hyprland-desktop.nix now puts the schemas
      # there, so this is no longer load-bearing — but the failure it covers
      # took months to notice precisely because it was silent, and dconf
      # removes the dependency rather than satisfying it. Same database, same
      # D-Bus change notification, no schema lookup; it is what ../qt.nix and
      # the autoLightDark helper above already use, for the reasons spelled
      # out there.
      #
      # sed rather than substituteInPlace, and on one line at a time: the two
      # writes sit inside an if/elif, and a multi-line anchor would need its
      # indentation spelled exactly. The capture carries the value, so one
      # expression covers prefer-dark and prefer-light without naming either.
      #
      # dconf takes a GVariant, so a string value needs its quotes inside the
      # argument: "'prefer-dark'", not 'prefer-dark'.
      before=$(grep -c "gsettings set org.gnome.desktop.interface" "$f" || true)
      [ "$before" = "4" ] || {
        echo "pre_process: expected 4 gsettings writes, found $before" >&2
        exit 1
      }
      sed -i \
        -e "s|gsettings set org\.gnome\.desktop\.interface color-scheme '\(.*\)'|${pkgs.dconf}/bin/dconf write /org/gnome/desktop/interface/color-scheme \"'\1'\"|" \
        -e "s|gsettings set org\.gnome\.desktop\.interface gtk-theme '\(.*\)'|${pkgs.dconf}/bin/dconf write /org/gnome/desktop/interface/gtk-theme \"'\1'\"|" \
        "$f"
      [ "$(grep -c "gsettings set org.gnome.desktop.interface" "$f" || true)" = "0" ] || exit 1
      [ "$(grep -c "dconf write /org/gnome/desktop/interface" "$f" || true)" = "4" ] || exit 1
    done

    # ── The lock screen palette must not leak into the desktop.
    #
    # Setting a lock screen wallpaper runs switchwall.sh --colors_lock, which
    # is meant to produce colors-lock.json and nothing else. Two things leaked:
    #
    #   pre_process() still ran, so a dark lock wallpaper behind a light
    #   desktop wrote prefer-dark to dconf. Zen, VS Code and every GTK/Qt app
    #   follow that key live and turned dark while the shell stayed light,
    #   until they were restarted after the next real wallpaper change.
    #
    #   matugen writes every target in matugen/config.toml, but only
    #   colors.json and the two gtk.css were backed up and put back — so
    #   Hyprland's border colours, fuzzel, hyprlock and color.txt silently
    #   took the lock palette.
    #
    # The mode is still derived from the lock image; it only steers that
    # palette now, not the session.
    substituteInPlace $qs/scripts/colors/switchwall.sh \
      --replace-fail '    pre_process "$mode_flag"' \
                     '    [[ -n "$colors_lock_flag" ]] || pre_process "$mode_flag"' \
      --replace-fail '        "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"' \
                     '        "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
            "$XDG_CONFIG_HOME/hypr/hyprland/colors.lua"
            "$XDG_CONFIG_HOME/hypr/hyprlock/colors.conf"
            "$XDG_CONFIG_HOME/fuzzel/fuzzel_theme.ini"
            "$STATE_DIR/user/generated/color.txt"
            "$STATE_DIR/user/generated/wallpaper/path.txt"'
    # Guard against matugen gaining a target this list does not restore.
    [ "$(grep -c "^output_path" $out/.config/matugen/config.toml)" = "8" ] || {
      echo "matugen/config.toml: target count changed, update the colors_lock restore list" >&2
      exit 1
    }
  '';
}
