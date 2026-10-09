# ── Idle and lid: the display is the only thing that ever turns off.
#
# The machine never sleeps on its own — logind ignores the lid and both
# power keys (../../modules/power.nix), and the one thing left that could
# still end a session unattended is UPower's poweroff at 12%, same file.
# What remains here is purely about the screen:
#
#   on AC       nothing, ever: no screen-off, no lock
#   on battery  screen off after 5 min idle, lock at 15 min
#   lid closed  the internal panel goes dark, nothing else changes
{ pkgs, lib, qsConfig, fill, ... }: rec {
  # hypridle has no notion of power source, so every listener goes through
  # this script and the AC check happens at the moment the timeout fires.
  # Called by name from hypridle.conf rather than by store path: that file is
  # seed-once (see mutablePaths) and outlives any store path baked into it.
  #
  # Two Hyprland behaviours, both verified on this machine, shape the lid half:
  #
  # A dpms dispatch naming an output that is not active does not fail — it
  # falls through to EVERY monitor. With eDP-1 switched off in nwg-displays,
  # a lid close would have blacked out the HDMI screen. So the panel is only
  # ever named after `hyprctl monitors` (which lists active outputs only) has
  # confirmed it is there.
  #
  # And key_press/mouse_move_enables_dpms wake a per-monitor dpms-off just as
  # they wake a global one: with the lid shut, the first touch of an external
  # mouse lit the closed panel again. Those two are turned off for as long as
  # the lid is closed, and `wake` (hypridle's on-resume) takes over waking the
  # other screens without touching the panel.
  displayPower = pkgs.writeShellScriptBin "ii-display-power" (fill ./files/display-power.sh {
    path = lib.makeBinPath [ pkgs.hyprland pkgs.jq pkgs.coreutils pkgs.gnugrep pkgs.systemd ];
  });

  # Replaces upstream's hypridle.conf outright: its three listeners (lock 5m,
  # screen off 10m, suspend 15m) all fire regardless of power source, and the
  # suspend one is exactly what this setup is removing. general {} is
  # upstream's, verbatim — manual suspend (SUPER+SHIFT+L) still locks first.
  #
  # Seed-once like the rest of mutablePaths: an existing
  # ~/.config-ii/hypr/hypridle.conf is not replaced. Delete it to pick this up.
  hypridleConf = pkgs.writeText "hypridle.conf" (builtins.readFile ./files/hypridle.conf);

  patch = ''
    # Upstream ships the lid bind commented out, as a suspend. It becomes the
    # panel-off/on pair instead; locked so it still fires on the lock screen.
    sed -i 's|^-- hl.bind("switch:on:Lid Switch", .*$|hl.bind("switch:on:Lid Switch", hl.dsp.exec_cmd("${displayPower}/bin/ii-display-power lid-close"), { locked = true }) -- # [hidden]\nhl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd("${displayPower}/bin/ii-display-power lid-open"), { locked = true }) -- # [hidden]|' \
      $out/.config/hypr/hyprland/keybinds.lua
    grep -q '^hl.bind("switch:off:Lid Switch"' $out/.config/hypr/hyprland/keybinds.lua

    cp ${hypridleConf} $out/.config/hypr/hypridle.conf

    # The shell's own battery suspend (18% in this config.json) would put the
    # machine to sleep before it ever reached UPower's 12% poweroff, and a
    # suspended machine checks nothing — it would drain to zero asleep. Its
    # low/critical notifications are kept; only the suspend goes. As with the
    # capture paths, this is the QML default: an existing config.json that
    # already says true still wins.
    substituteInPlace $out/.config/quickshell/${qsConfig}/modules/common/Config.qml \
      --replace-fail 'property bool automaticSuspend: true' 'property bool automaticSuspend: false'
    for f in $out/.config/quickshell/ii/modules/common/Config.qml; do
      [ -e "$f" ] || continue
      sed -i 's|property bool automaticSuspend: true|property bool automaticSuspend: false|' "$f"
    done
  '';
}
