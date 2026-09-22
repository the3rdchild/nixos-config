{ config, inputs, pkgs, ... }:
{
  # ── System-level support shared by every Hyprland session on this machine.
  #
  # The Hyprland package/session itself is enabled in ./package.nix, and the
  # session that actually runs is defined in ./ii-session.nix; this module
  # only adds what has to exist outside home-manager and is not specific to
  # either — the portal stack, a dconf backend and its schemas, a polkit
  # policy daemon, geoclue, ydotool, and the CTRL+ESC keyd remap.
  #
  # It was written as "system-level support for the caelestia dots" and
  # renamed when that session was dropped. Nothing in it was caelestia-
  # specific; the per-user half that was lives in git history.

  # execs.lua drives cursor + GTK appearance through `gsettings`, which
  # needs a dconf backend to persist anything.
  programs.dconf.enable = true;

  # ── And the other half of what `gsettings` needs: the schemas.
  #
  # A backend is not enough. Without a schema for the key being touched,
  # gsettings does not fall back to anything — it exits 1 with "No schemas
  # installed" and, in a script that redirects stderr, in total silence.
  # That is what every `gsettings` call on this machine did: nothing.
  #
  # Nothing put them on XDG_DATA_DIRS. glib.bin is installed and supplies the
  # `gsettings` binary, but the schemas live in gsettings-desktop-schemas,
  # which was in neither profile, and neither /run/current-system/sw/share/
  # glib-2.0/schemas nor .../gsettings-schemas exists. The only reason this
  # was not obvious everywhere is that wrapGAppsHook bakes the path into each
  # app's own wrapper, so VS Code and xdg-desktop-portal-gtk kept working
  # while every bare shell call did not.
  #
  # What it cost, before this line existed: switchwall.sh's pre_process()
  # never wrote org.gnome.desktop.interface color-scheme, so the session mode
  # froze at whatever had last been written by something using dconf directly
  # — a black wallpaper left the whole desktop in light mode, the portal told
  # Zen and VS Code "light", and kde-material-you-colors-wrapper.sh read an
  # empty mode and picked -l, which is what put Dolphin there too. Twenty call
  # sites across both shells, all of them org.gnome.desktop.interface, all of
  # them dead.
  #
  # sessionVariables rather than systemPackages: the schemas have to be found
  # through XDG_DATA_DIRS, and a package in the system profile puts them at
  # share/gsettings-schemas/<name>/glib-2.0/schemas — a level deeper than the
  # share/ that is on the path. Naming the directory is the whole fix, and it
  # keeps the package in the system closure on its own.
  #
  # This list merges with the entries NixOS already contributes (the desktops
  # share dir, then every profile's share/), so nothing is displaced.
  environment.sessionVariables.XDG_DATA_DIRS = [
    "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}"
  ];

  # The polkit agent the session starts from its own execs.lua is only a
  # client. The policy daemon it talks to still has to be running.
  security.polkit.enable = true;

  # gammastep's auto-location. The demo agent execs.lua launches is only the
  # client half — without the system service there is no provider to ask.
  services.geoclue2.enable = true;

  # CTRL+SHIFT+ALT+V types the last clipboard entry via ydotool. This needs
  # the ydotoold daemon and /dev/uinput access, so it can't be a home
  # package — see the ydotool group added in ./user.nix.
  programs.ydotool.enable = true;

  # ── CTRL+ESC as a second SUPER.
  #
  # Remapped at the evdev level (keyd), not in Hyprland: the compositor
  # receives a real LEFT_META while CTRL+ESC is held, so every SUPER bind
  # works unchanged — keybinds, SUPER+mouse move/resize, the SUPER-tap
  # launcher — with zero bind duplication. ESC alone and CTRL alone are
  # untouched; only the chord emits META.
  #
  # swap(), not a plain `esc = meta`: mapping to a bare keycode only strips
  # CTRL from that single event, leaving keyd inside the [control] layer for
  # as long as CTRL is physically held — so the *next* key arrives as
  # CTRL+SUPER+key. Hyprland matches modmasks exactly, so no SUPER bind ever
  # fired, and CTRL leaking through let VS Code / Zen claim the chord.
  # swap(meta) tears down the control layer and stands up the built-in meta
  # layer for the duration of ESC's depression, so CTRL is genuinely released.
  # Press order therefore matters: CTRL first, then ESC, holding both.
  #
  # Conflict check (Aug 2026): nothing in the session's keybinds.lua or this
  # config uses CTRL+ESC. The one ESC bind that exists is CTRL+SHIFT+Escape
  # (kbSystemMonitorWs, variables.lua:87). keyd resolves chords through
  # composite layers in activation order, so SHIFT-then-CTRL-then-ESC would
  # otherwise land in [control] and emit META instead — the two composite
  # layers below pin ESC back to itself in both orders.
  services.keyd = {
    enable = true;
    keyboards.default = {
      # "*" is every device keyd identifies as a keyboard — which would
      # include the two virtual devices ./mousekeys.nix creates. keyd would
      # grab the mousekeys keyboard and re-emit it onto the very node the
      # mousekeys daemon reads, and every keystroke would circulate forever.
      # These two ids are the ones set as KBD_/PTR_VENDOR:PRODUCT there; the
      # pair must stay in sync with that file.
      ids = [ "*" "-feed:0001" "-feed:0002" ];
      settings = {
        control.esc = "swap(meta)";
        "control+shift".esc = "esc";
        "shift+control".esc = "esc";
      };
    };
  };

  # NOTE: the lock screen DOES need a PAM entry, and it is not here —
  # ./ii-session.nix sets programs.hyprlock.enable, which adds pam.d/hyprlock
  # along with the binary. This note used to say the opposite, and correctly
  # so: the caelestia session locked with a QML locker that pointed PAM at a
  # config dir inside its own package. That locker is gone; do not carry its
  # conclusion over to hyprlock, which refuses every password without the
  # /etc/pam.d entry.

  # No polkit_gnome here. The agent is started by store path from the
  # session's own execs.lua, so the package never had to be on the system
  # profile. Having it there put its XDG autostart entry in
  # /run/current-system/sw/etc/xdg/autostart, which under a UWSM session
  # actually runs (xdg-desktop-autostart.target), loses the race to the agent
  # that is already registered ("An authentication agent already exists for
  # the given subject"), and leaves a failed user unit behind on every login.
  environment.systemPackages = with pkgs; [
    xdg-desktop-portal-hyprland
    xdg-desktop-portal-gtk # Settings backend (colour scheme); see ../home/vscode.nix
    kdePackages.xdg-desktop-portal-kde # file picker, see xdg.portal.config below
    xdg-user-dirs # screenshot/recording paths resolve through this
  ];

  # Same order xdg-desktop-portal-hyprland ships in hyprland-portals.conf, plus
  # one override: the file picker comes from kde instead of gtk. VS Code's
  # Open Folder, Zen's upload/save dialogs, OBS etc. all ask the portal, and
  # the gtk picker looked like thunar next to dolphin; the kde one shares
  # dolphin's KIO places sidebar and icons. Everything else (screencast,
  # screenshot, settings) stays hyprland;gtk.
  xdg.portal.config.hyprland = {
    default = [ "hyprland" "gtk" ];
    "org.freedesktop.impl.portal.FileChooser" = [ "kde" ];
  };
}
