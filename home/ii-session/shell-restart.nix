# ── Restarting the shell.
#
# Upstream's bind is `killall ydotool qs quickshell; qs -c $qsConfig &`, and
# on NixOS the kill half is a no-op: wrapQtAppsHook renames the process, so
# /proc/<pid>/comm reads `.quickshell-wra` and killall — which matches on
# comm — finds neither `qs` nor `quickshell`. The start half still runs, so
# every press of CTRL+SUPER+R left the old instance alive and added another
# one: two bars, then three. Upstream knows about this; it is an open TODO in
# their own sdata/dist-nix/README.md ("should be .quickshell-wra and
# .Hyprland-wrapp when installed via Nix").
#
# `qs kill` is quickshell's own subcommand and the right answer here: these
# configs live at $XDG_CONFIG_HOME/quickshell/<name>, so -c resolves. pkill
# on the full command line stays as a backstop for an instance that is too
# wedged to answer its IPC socket.
#
# The sidebar's "Reload Hyprland & Quickshell" buttons go the same way. They
# call Quickshell.reload(true), which rebuilds the whole scene inside the
# running process; on quickshell 0.3.1 that segfaulted in Qt Quick's teardown
# (the reasons are in ../../flake.nix, at the quickshell input). A restart
# through this script never takes that path. It costs a fresh process start
# instead of an in-place swap.
{ pkgs, lib, qsConfig, fill, ... }: let
  shellRestart = pkgs.writeShellScript "ii-shell-restart" (fill ./files/shell-restart.sh {
    path = lib.makeBinPath [ pkgs.procps pkgs.psmisc pkgs.coreutils ];
    inherit qsConfig;
  });
in {
  patch = ''
    substituteInPlace $out/.config/hypr/hyprland/keybinds.lua \
      --replace-fail \
        'hl.dsp.exec_cmd("killall ydotool qs quickshell; qs -c $qsConfig &")' \
        'hl.dsp.exec_cmd("${shellRestart}")'

    # The About page restarts the shell the same broken way.
    for f in $out/.config/quickshell/*/modules/ii/settings/pages/About.qml; do
      [ -e "$f" ] || continue
      sed -i 's|killall qs 2>/dev/null \|\| true|qs kill 2>/dev/null \|\| pkill -f '"'"'quickshell -c'"'"' 2>/dev/null \|\| true|' "$f"
    done

    # The reload buttons: `hyprctl reload` stays as upstream has it, and the
    # in-process shell reload after it becomes the restart script. ii has one
    # such button, end4-pC two (the second also serves niri).
    for f in $out/.config/quickshell/*/modules/ii/sidebarRight/SidebarRightContent.qml; do
      [ -e "$f" ] || continue
      case "$f" in
        */quickshell/ii/*) want=1 ;;
        *) want=2 ;;
      esac
      [ "$(grep -c 'Quickshell\.reload(true);' "$f")" = "$want" ] || {
        echo "$f: expected $want Quickshell.reload(true) call sites" >&2
        exit 1
      }
      sed -i 's|Quickshell\.reload(true);|Quickshell.execDetached(["${shellRestart}"]);|' "$f"
      [ "$(grep -c 'Quickshell\.reload(' "$f")" = "0" ] || exit 1
      [ "$(grep -cF '${shellRestart}' "$f")" = "$want" ] || exit 1
    done
  '';
}
