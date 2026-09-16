{ config, inputs, pkgs, ... }:
{
  # ── System-level support for the caelestia dots.
  #
  # The Hyprland package/session itself is enabled in ./package.nix; this
  # module only adds what has to exist outside home-manager. The per-user
  # half — the shell, the hypr Lua config, the app configs — lives in
  # ../home/caelestia.nix.
  #
  # Unlike the JaKooLit setup this replaced, ~/.config/hypr IS managed
  # declaratively now. Caelestia keeps its mutable state out of the config
  # tree (~/.local/state/caelestia) and confines runtime writes to
  # hypr/scheme/current.lua, so per-file symlinks work.

  # execs.lua drives cursor + GTK appearance through `gsettings`, which
  # needs a dconf backend to persist anything.
  programs.dconf.enable = true;

  # The polkit-gnome agent (services.polkit-gnome under UWSM, execs.lua in the
  # plain session; see ../home/caelestia.nix) is only a client. The policy
  # daemon it talks to still has to be running.
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
  # Conflict check (Aug 2026): nothing in caelestia's keybinds.lua or this
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

  # NOTE: the lock screen does NOT need a security.pam.services entry. It
  # points PAM at its own config dir inside the package
  # (Quickshell.shellPath("assets/pam.d") in modules/lock/Pam.qml) rather
  # than /etc/pam.d, and authenticates via pam_unix + the setuid
  # unix_chkpwd helper NixOS already provides in /run/wrappers.

  # No polkit_gnome here. Both ways the agent is started run it by store path
  # (the home-manager unit and the execs.lua patch in ../home/caelestia.nix),
  # so the package never had to be on the system profile. Having it there
  # put its XDG autostart entry in /run/current-system/sw/etc/xdg/autostart.
  # Under UWSM that entry actually runs (xdg-desktop-autostart.target), loses
  # the race to the agent that is already registered ("An authentication
  # agent already exists for the given subject"), and leaves a failed user
  # unit behind on every login.
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
