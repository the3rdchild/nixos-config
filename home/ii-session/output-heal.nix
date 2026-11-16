# ── An output that Hyprland stops advertising after a mirror is undone.
#
# Seen on Hyprland 0.56.0: mirror HDMI-A-1 from nwg-displays, then put it
# back to a normal extended output. Hyprland's own state is right afterwards
# (`hyprctl monitors` lists it with mirrorOf none, `wlr-randr` agrees), but
# the output is no longer a wl_output global, so no layer-shell client can
# see it. quickshell builds its windows from Quickshell.screens, which then
# holds only the laptop panel — no wallpaper, no bar, nothing on the external
# screen, and restarting the shell changes nothing because the screen is not
# on offer. Switching the output off and on again makes Hyprland re-create it.
#
# This is that off/on, done automatically. It listens on Hyprland's event
# socket and, after a reload or a monitor coming or going has settled, compares
# the outputs Hyprland considers live with the wl_outputs actually advertised
# (wayland-info). Anything live but not advertised is disabled and the config
# reloaded, which re-applies monitors.lua. When nothing is missing it does
# nothing, so a healthy session never sees a flicker.
#
# Started from execs.lua, i.e. once per Hyprland start, like the clipboard
# watchers.
{ pkgs, lib, fill, ... }: rec {
  outputHeal = pkgs.writeShellScript "ii-output-heal" (fill ./files/output-heal.sh {
    path = lib.makeBinPath [
      pkgs.hyprland pkgs.jq pkgs.socat pkgs.wayland-utils
      pkgs.libnotify pkgs.gnused pkgs.coreutils
    ];
  });

  patch = ''
    sed -i '/^    hl.exec_cmd("easyeffects --hide-window --service-mode")$/a\    hl.exec_cmd("${outputHeal}") -- Re-creates an output left unadvertised after un-mirroring; see output-heal.nix' \
      $out/.config/hypr/hyprland/execs.lua
    grep -q 'output-heal.nix' $out/.config/hypr/hyprland/execs.lua
  '';
}
