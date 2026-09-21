{ config, lib, pkgs, ... }:
let
  cfgDirName = ".config-ii";

  # ── How session B starts.
  #
  # Setting XDG_CONFIG_HOME is the whole mechanism. Hyprland looks for its
  # config under $XDG_CONFIG_HOME/hypr before $HOME/.config/hypr and picks up
  # hyprland.lua on its own — verified with `XDG_CONFIG_HOME=... Hyprland
  # --verify-config`, which reported "Using lua config found at
  # <dir>/hypr/hyprland.lua". So no -c is needed, and more importantly every
  # other program launched from this session reads the same alternate root
  # without being told: fish, kitty, foot, fontconfig, kdeglobals, Kvantum,
  # matugen, fuzzel, dconf. That is what keeps the caelestia session's
  # ~/.config completely untouched.
  #
  # start-hyprland, not Hyprland, to match the plain session entry that ships
  # in the Hyprland package — it is the watchdog wrapper.
  #
  # Deliberately NOT uwsm. Under uwsm the compositor runs as a user unit and
  # graphical-session.target is reached, which would start the caelestia shell,
  # the polkit agent and both cliphist watchers (../home/caelestia.nix) on top
  # of this session — two shells fighting over the same layer surfaces. Plain
  # Hyprland never reaches that target, so those units stay asleep and ii's own
  # execs.lua starts its equivalents. This is the same fallback path the plain
  # "Hyprland" entry already uses.
  launcher = pkgs.writeShellScriptBin "start-hyprland-ii" ''
    export XDG_CONFIG_HOME="$HOME/${cfgDirName}"
    exec ${config.programs.hyprland.package}/bin/start-hyprland
  '';

  session = pkgs.writeTextFile {
    name = "hyprland-ii-session";
    destination = "/share/wayland-sessions/hyprland-ii.desktop";
    text = ''
      [Desktop Entry]
      Name=Hyprland (illogical-impulse)
      Comment=Hyprland with the end-4 / end4-pC dots, from a separate config root
      Exec=${launcher}/bin/start-hyprland-ii
      TryExec=${launcher}/bin/start-hyprland-ii
      Type=Application
      DesktopNames=Hyprland
    '';
  };
in
{
  # ── The third entry in the greeter.
  #
  # The other two ("Hyprland" and "Hyprland (uwsm-managed)") ship inside the
  # Hyprland package itself; sessionPackages is how a session that isn't part
  # of a package gets listed. defaultSession stays hyprland-uwsm in ./sddm.nix
  # on purpose — if this session fails to come up, the greeter still offers the
  # working one rather than looping on a broken default. SDDM does remember the
  # last session per user, so after picking this one it will be preselected.
  services.displayManager.sessionPackages = [ session ];

  # ── hyprlock.
  #
  # The caelestia session locks with its own QML locker, which points PAM at a
  # config dir inside its package and so never needed an /etc/pam.d entry (see
  # the note in ./hyprland-desktop.nix). ii locks with hyprlock, which does:
  # without this option there is no pam.d/hyprlock and the lock screen refuses
  # every password. Enabling it adds the PAM entry and the binary and changes
  # nothing for session A.
  programs.hyprlock.enable = true;

  # ── Fonts, system-wide rather than in home.packages.
  #
  # This is not a style choice. home-manager makes profile fonts visible by
  # writing ~/.config/fontconfig/conf.d/10-hm-fonts.conf — which lives in
  # ~/.config, the root session B does not read. Fonts installed into the user
  # profile would therefore be invisible in exactly the session that needs
  # them. The system font dir is picked up from /etc/fonts/fonts.conf, which
  # fontconfig reads regardless of XDG_CONFIG_HOME.
  #
  # google-fonts covers three of the four families the QML names — Readex Pro
  # ("reading"), Space Grotesk ("expressive") and Caveat. material-symbols is
  # the icon font. rubik stands in for Google Sans Flex, which is Google's
  # brand font and packaged nowhere; ../home/ii-session.nix patches the QML to
  # ask for it. JetBrainsMono NF is already in ./fonts.nix.
  fonts.packages = with pkgs; [
    google-fonts
    material-symbols
    rubik
  ];

  # gnome-keyring: ii's execs.lua starts the daemon's secrets component, but
  # the PAM half — unlocking the login keyring with the login password — has to
  # be enabled system-wide, and the daemon needs its D-Bus services.
  services.gnome.gnome-keyring.enable = true;

  # The geoclue demo agent, which start_geoclue_agent.sh launches (patched to
  # the store path in ../home/ii-session.nix). The geoclue2 *service* is
  # already on from ./hyprland-desktop.nix; this is only the agent half.
  environment.systemPackages = [ pkgs.geoclue2-with-demo-agent ];
}
