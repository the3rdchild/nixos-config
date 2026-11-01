# ── The Hyprland portal must not outlive its compositor.
#
# xdg-desktop-portal-hyprland is a systemd user service, and the user manager
# keeps running when Hyprland exits (logging out and in, a restart, a crash).
# graphical-session.target never stops in this session, so the service's
# PartOf= does nothing, and 1.4.0 does not exit when its Wayland connection
# dies: it spins on the dead socket, two threads at ~100% and ~70% — about 1.7
# cores, for as long as the manager lives. It also keeps the old
# HYPRLAND_INSTANCE_SIGNATURE, so even if it behaved it would serve the
# compositor that is gone.
#
# On every Hyprland start: put this session's variables into the manager,
# then try-restart the portal. try-restart does nothing when it is not
# running (the first login of a boot), where D-Bus activation starts it with
# the right environment anyway. Importing first is not optional: the
# dbus-update-activation-environment lines above only reach the manager
# asynchronously, and a restart that beat them would come back stale.
{ ... }: {
  patch = ''
    substituteInPlace $out/.config/hypr/hyprland/execs.lua --replace-fail \
      'XDG_CURRENT_DESKTOP") -- Some fix idk' \
      'XDG_CURRENT_DESKTOP") -- Some fix idk
        -- The portal from the previous Hyprland session spins on its dead connection; see portal-restart.nix
        hl.exec_cmd("systemctl --user import-environment HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY XDG_CURRENT_DESKTOP && systemctl --user try-restart xdg-desktop-portal-hyprland")'
    grep -q 'try-restart xdg-desktop-portal-hyprland' $out/.config/hypr/hyprland/execs.lua
  '';
}
