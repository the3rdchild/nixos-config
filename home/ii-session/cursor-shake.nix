# ── Shake the pointer to find it, as on macOS.
#
# Hyprland 0.56 has nothing like it, so ./files/cursor-shake.py does it:
# it polls the pointer position over Hyprland's socket (~80 Hz while the
# pointer moves, 20 Hz once it has been still; a request costs ~10 µs),
# counts quick reversals of direction, and on three of them within 0.7 s
# enlarges the cursor with `setcursor`, 4x, then shrinks it again a second
# after the shaking stops. Polling the compositor rather than reading evdev
# covers the touchpad and modules/mousekeys.nix too, and needs no `input`
# group.
#
# `hyprctl setcursor` redraws the compositor's own cursor, which is what
# every client that uses cursor-shape-v1 shows; the one test run on this
# machine grew it over every window.
#
# Hyprland cannot be asked what cursor it is using, so the daemon is also
# where the session's cursor is set at login: it replaces upstream's
# `hyprctl setcursor Bibata-Modern-Classic 24` line in execs.lua and takes
# the same two values. Change them here, not in the lua.
#
# execs.lua only runs when Hyprland starts. To get it in a running session:
#   ii-cursor-shake Bibata-Modern-Classic 24 & disown

{ pkgs, ... }: rec {
  cursorTheme = "Bibata-Modern-Classic";
  cursorSize = 24;

  cursorShake = pkgs.writeScriptBin "ii-cursor-shake"
    "#!${pkgs.python3}/bin/python3 -I\n${builtins.readFile ./files/cursor-shake.py}";

  patch = ''
    substituteInPlace $out/.config/hypr/hyprland/execs.lua --replace-fail \
      'hl.exec_cmd("hyprctl setcursor Bibata-Modern-Classic 24")' \
      'hl.exec_cmd("${cursorShake}/bin/ii-cursor-shake ${cursorTheme} ${toString cursorSize}")'
  '';
}
