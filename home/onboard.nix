# Auto-start `onboard` (on-screen keyboard) at login for the noouoops user.
#
# Why a custom .desktop instead of symlinking upstream's
# `onboard-autostart.desktop`?
#
#   The upstream entry ships with two GNOME-only guards that make XDG
#   autostart silently skip it on every other desktop:
#
#     OnlyShowIn=GNOME;Unity;MATE;
#     AutostartCondition=GSettings org.gnome.desktop.a11y.applications \
#                                  screen-keyboard-enabled
#
#   Plasma6, Hyprland, etc. honour OnlyShowIn strictly, so the file would be
#   ignored — which is exactly why `onboard` had to be launched by hand.
#   This custom entry drops both guards so it starts on any session that
#   respects `~/.config/autostart/*.desktop` (Plasma6, and most XDG-aware
#   compositors).
#
#   For Hyprland specifically, XDG autostart is NOT processed by default —
#   add `exec-once = onboard --startup-delay=3.0` to hyprland.conf there.
{ pkgs, ... }:
{
  xdg.configFile."autostart/onboard.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Onboard
    GenericName=Onboard onscreen keyboard
    Comment=Auto-start the on-screen keyboard at login
    Exec=${pkgs.onboard}/bin/onboard --startup-delay=3.0
    Icon=onboard
    Terminal=false
    NoDisplay=true
    X-GNOME-AutoRestart=true
  '';

  # NOTE on the AppIndicator D-Bus warning at startup:
  #   "Failed to setup D-Bus match rule ... for AppIndicator"
  # This is harmless. Onboard tries to register a tray icon via the
  # AppIndicator/SNI protocol; if the session's status-notifier host
  # doesn't expose that interface cleanly the match-rule setup logs a
  # warning but the keyboard itself works fine. No action needed.
}
