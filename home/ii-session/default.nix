# ── The session: illogical-impulse + the end4-pC fork.
#
# This directory owns a config root of its own, and the session is launched
# with XDG_CONFIG_HOME pointed at it:
#
#   ~/.config/      home-manager's own output, for shells and apps started
#                   outside the session (see ../shell.nix)
#   ~/.config-ii/   illogical-impulse  (everything here)
#
# The split is what makes the whole tree a store symlink with a small,
# listed set of mutable exceptions (see mutablePaths), rather than
# home-manager and the dots fighting over one ~/.config.
#
# It is cheap because the shell half of these dots is already XDG-aware —
# 33 sites across ii and end4-pC read ${XDG_CONFIG_HOME:-$HOME/.config}
# rather than hardcoding. Everything else that matters (fish, kitty, foot,
# fontconfig, kdeglobals, Kvantum, matugen, fuzzel, wlogout, mpv, dconf)
# honours XDG_CONFIG_HOME on its own, so nothing here has to be told twice
# where its config lives. What is NOT XDG-aware is the Hyprland Lua config
# and a dozen helper scripts, which spell $HOME/.config literally; ./dots.nix
# rewrites those.
#
# Layout:
#
#   dots.nix        the patched tree: upstream + end4-pC, made to run on NixOS
#   <feature>.nix   one change each — its scripts, its QML and its patch
#   files/          the scripts and QML snippets, as the store gets them
#                   (@name@ placeholders are filled in by `fill` below)
#   packages.nix    everything the session reaches for by name
{
  config,
  inputs,
  pkgs,
  lib,
  ...
}: let
  cfgDirName = ".config-ii";
  cfgDir = "${config.home.homeDirectory}/${cfgDirName}";

  # Which quickshell config the session starts. Both are installed side by
  # side under .config-ii/quickshell/, so this is only the default: `qs -c ii`
  # and `qs -c end4-pC` switch at runtime, no rebuild, no logout.
  qsConfig = "end4-pC";

  # Reads one of ./files, filling in its @name@ placeholders from `vars`.
  # The files hold exactly the text the derivations write, so moving a
  # script out of a Nix string changes no store path.
  fill = file: vars:
    lib.replaceStrings
      (map (n: "@${n}@") (lib.attrNames vars))
      (map toString (lib.attrValues vars))
      (builtins.readFile file);

  args = { inherit config inputs pkgs lib qsConfig fill; };

  # ── The features, in the order their patches are applied.
  python = import ./python.nix args;
  terminals = import ./terminals.nix args;
  microtex = import ./microtex.nix args;
  kde = import ./kde.nix args;
  keybinds = import ./keybinds.nix args;
  capture = import ./capture.nix args;
  display = import ./display-power.nix args;
  lightDark = import ./light-dark.nix (args // { inherit (video) videoFrame; });
  video = import ./video-wallpaper.nix args;
  barIslands = import ./bar-islands.nix args;
  clipboard = import ./clipboard.nix args;
  restart = import ./shell-restart.nix args;
  ai = import ./ai.nix args;

  dots = import ./dots.nix (args // {
    inherit cfgDirName;
    patches = map (f: f.patch) [
      python
      terminals
      microtex
      kde
      keybinds
      capture
      display
      lightDark
      video
      barIslands
      clipboard
      restart
      ai
    ];
  });

  # ── Zen's accent, from this session's palette.
  #
  # ../zen-wallpaper-accent.nix carries the whole explanation of why Zen
  # needs a CSS file pushed into its profile rather than a pref, and
  # ../zen.nix owns the userChrome.css that consumes it. Only two things are
  # this session's business: which colours.json is the source, and what runs
  # the script — both below. The source is matugen's m3colors output as
  # ~/.config-ii/matugen/config.toml routes it; nothing else writes it.
  zenAccent = import ../zen-wallpaper-accent.nix { inherit pkgs; };
  zenAccentColors = "${config.home.homeDirectory}/.local/state/quickshell/user/generated/colors.json";

  # ── Files these dots write to at runtime.
  #
  # home-manager's recursive source makes real directories but symlinks every
  # file into the store, and writing through such a symlink is EACCES. These
  # are the paths something actually writes, so they are pulled out of the
  # linked tree and seeded as real copies instead (the activation below).
  #
  # Seeded once, then yours: a rebuild will not overwrite one that exists. That
  # is upstream's own model for the custom/ folder, and without it the Settings
  # panel would be decorative — every nixos-rebuild would revert it. The price
  # is that these paths are not reproducible from the flake; delete one to
  # have it seeded again.
  #
  #   hypr/custom/                  6 files created at startup by
  #                                 hyprland/services/create_custom_config.lua
  #   hypr/hypridle.conf            hypridleconfigurator.py
  #   hypr/hyprland/shellOverrides/ hyprconfigurator.py
  #   hypr/monitors.lua             monitor_configurator.py (not shipped)
  #   matugen/config.toml           end4-pC services/SystemTheming.qml, which
  #                                 backs it up once as config.toml.orig and
  #                                 regenerates it whenever a matugen template
  #                                 is toggled in Settings
  #   the five matugen outputs      rewritten on every wallpaper change
  #
  # Second group: application configs that the applications themselves rewrite.
  # These are not shell state — they are ordinary app config files that happen
  # to be shipped by these dots, and every one of them belongs to a program
  # that saves over it. fish/fish_variables is the one that proved the rule: it
  # is fish's universal-variable store, written on every `set -U`, so a
  # symlinked one turns every new shell in the session into a wall of
  # "Read-only file system (os error 30)".
  #
  # kdeglobals matters most of the two dozen: KDE apps rewrite it on any
  # appearance change, and the colour pipeline writes it too — matugen's
  # templates/kde/kde-material-you-colors-wrapper.sh regenerates it from the
  # wallpaper. Read-only, the whole Qt side of the theming silently stops.
  #
  # If some other app here turns out to save over its config, the fix is one
  # more line in this list.
  mutablePaths = [
    "fish/fish_variables"
    "kdeglobals"
    "dolphinrc"
    "konsolerc"
    "darklyrc"
    "Kvantum/kvantum.kvconfig"
    "kde-material-you-colors/config.conf"

    "hypr/custom"
    "hypr/hypridle.conf"
    "hypr/hyprlock.conf"
    "hypr/hyprland/shellOverrides"
    "hypr/hyprland/colors.lua"
    "hypr/hyprlock/colors.conf"
    "hypr/monitors.lua"
    "matugen/config.toml"
    "fuzzel/fuzzel_theme.ini"
    "gtk-3.0/gtk.css"
    "gtk-4.0/gtk.css"
  ];

  # Paths kept as one definition, shared with ~/.config rather than shipped
  # by the dots. The comment on home.file says why these four and nothing
  # else.
  sharedFromConfigHome = [ "git" "menus" "mimeapps.list" "dconf" ];

  # The tree minus the mutable paths — this is what gets symlinked.
  linked = pkgs.runCommand "illogical-impulse-linked" { } ''
    cp -r ${dots}/.config $out
    chmod -R u+w $out
    ${lib.concatMapStringsSep "\n" (p: "rm -rf $out/${p}") mutablePaths}
  '';

  # Just the mutable paths, for the seeding activation. Some of them are
  # generated at runtime and shipped by nobody; those simply aren't here.
  seed = pkgs.runCommand "illogical-impulse-seed" { } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (p: ''
      if [ -e ${dots}/.config/${p} ]; then
        mkdir -p "$(dirname $out/${p})"
        cp -r ${dots}/.config/${p} $out/${p}
      fi
    '') mutablePaths}
  '';
in {
  # ── The tree itself.
  #
  # recursive = true: a plain directory source symlinks the whole tree
  # read-only, and then nothing can create hypr/custom/*.lua or
  # illogical-impulse/config.json at runtime. recursive makes real directories
  # and symlinks the files individually.
  #
  # ── Tooling this session has to share with the rest of the user.
  #
  # The session reads ~/.config-ii, so everything home-manager writes into
  # ~/.config is invisible to it. For the dots that is the point — ii ships
  # its own fish, kitty, foot, fontconfig, gtk-3.0 and starship.toml, and
  # would rather not see home-manager's. But four of those paths are not
  # look-and-feel, and losing them breaks work rather than changing
  # appearance:
  #
  #   git            without ~/.config/git/config the only thing left is a
  #                  stale unmanaged ~/.gitconfig whose key is misspelled
  #                  `user.mail`, so git sees no address and refuses to commit
  #                  at all ("Author identity unknown"). It also drops
  #                  ../git.nix's url."git@github.com:".insteadOf, which is
  #                  the only reason pushes to an https remote go over SSH.
  #   mimeapps.list  default application for every file type
  #   menus          menus/applications.menu, from ../mime.nix
  #   dconf          light/dark mode and the GTK theme, inside and outside
  #                  the session alike
  #
  # dconf is the one that actually broke something visible. The session
  # started with no ~/.config-ii/dconf/user at all, so `gsettings get
  # org.gnome.desktop.interface color-scheme` answered 'default', the portal
  # reported color-scheme = 0 ("no preference") to every client, and all GTK
  # and Qt apps rendered light while the shell stayed on its last matugen
  # palette. The shell reads the same key as its source of truth
  # (scripts/colors/switchwall.sh, the `if [[ -z "$mode_flag" ]]` branch), so
  # it computed "light" too and the two disagreed about what it had computed.
  #
  # Sharing it also fixes a worse, non-deterministic half: dconf reads and
  # writes both go through a D-Bus-activated service, and ii's execs.lua runs
  # `dbus-update-activation-environment --all`, so which database that service
  # ends up bound to depends on whether it was activated before or after that
  # line ran. With one database the race stops mattering.
  #
  # The deliberate consequence: light/dark and the GTK theme are one setting
  # for the whole user — ../qt.nix and ../themes.nix watch these very keys
  # and follow. That is what was asked for, and it is the honest model
  # anyway: light/dark is a property of the person, not of the dotfiles.
  #
  # mkOutOfStoreSymlink rather than copying the same source into both trees:
  # this points at the live ~/.config path, so whatever home-manager
  # generates there is what this session reads, with no second definition
  # that can drift. Nothing writes to any of them through ~/.config — they
  # are read-only store symlinks there already — so the indirection costs
  # nothing.
  home.file =
    {
      ${cfgDirName} = {
        source = linked;
        recursive = true;
      };
    }
    # The four shared paths, linked at their live ~/.config location.
    // lib.listToAttrs (map (name:
      lib.nameValuePair "${cfgDirName}/${name}" {
        source = config.lib.file.mkOutOfStoreSymlink
          "${config.home.homeDirectory}/.config/${name}";
      }) sharedFromConfigHome);

  # ── VS Code follows the session's light/dark inside this config root too.
  #
  # ../vscode.nix already solves this for ~/.config: vscode-theme-settings
  # writes the theme matching dconf's color-scheme into Code/User/settings.json
  # (and its vscode-theme-sync watcher redoes it live, for this root too),
  # editing the JSONC in place rather than replacing it, because VS Code
  # rewrites that file itself and a store symlink would make it drop every
  # setting written that way.
  #
  # It reads its target from XDG_CONFIG_HOME at run time, so the same binary
  # serves both roots — hence ../vscode-theme-settings.nix. Without this,
  # VS Code in the session keeps whatever theme it was last on while
  # everything else on screen follows the wallpaper.
  home.activation.iiVscodeTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    XDG_CONFIG_HOME="${cfgDir}" run ${
      import ../vscode-theme-settings.nix { inherit pkgs; }
    }/bin/vscode-theme-settings
  '';

  # ── Seed-once copies of everything written at runtime.
  home.activation.iiSessionMutableConfigs =
    lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatMapStringsSep "\n" (p: ''
        if [ -e ${seed}/${p} ] && [ ! -e "${cfgDir}/${p}" ]; then
          run mkdir -p "$(dirname "${cfgDir}/${p}")"
          run cp -r ${seed}/${p} "${cfgDir}/${p}"
          run chmod -R u+w "${cfgDir}/${p}"
        fi
      '') mutablePaths
    );

  # ── What runs ii-zen-accent.
  #
  # A .path unit rather than a patch to switchwall.sh's post_process(), where
  # the VS Code colour hook lives. Two reasons: the palette is rewritten from
  # more places than a wallpaper change (a bare regenerate, --noswitch, the
  # shell re-applying after a restart), and watching the output file catches
  # all of them without having to find each caller; and it keeps one more
  # substituteInPlace out of the dots build, where every anchor is a thing
  # upstream can rename.
  #
  # PathChanged, not PathModified: matugen writes the file and closes it, and
  # PathChanged fires on that close rather than on each intermediate write —
  # so the script never reads a half-written colours.json.
  #
  # default.target, not graphical-session.target, for the reason ../qt.nix's
  # watcher spells out: the plain "Hyprland" fallback session in the greeter
  # never reaches graphical-session.target.
  systemd.user.paths.ii-zen-accent = {
    Unit.Description = "Watch this session's matugen palette for Zen's accent";
    Path = {
      PathChanged = zenAccentColors;
      Unit = "ii-zen-accent.service";
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.ii-zen-accent = {
    Unit.Description = "Write the wallpaper's accent into Zen's profile";
    Service = {
      Type = "oneshot";
      # Named explicitly because systemd --user does not run with this
      # session's XDG_CONFIG_HOME, and because the script's own default is
      # only right by coincidence — it happens to be the same path today, and
      # saying so here is what keeps this unit pointed at this session if
      # that default ever moves.
      Environment = [ "ZEN_ACCENT_COLORS=${zenAccentColors}" ];
      ExecStart = "${zenAccent}/bin/ii-zen-accent apply";
    };
  };

  home.packages = import ./packages.nix {
    inherit pkgs inputs zenAccent;
    inherit (python) venv;
    inherit (lightDark) autoLightDarkCtl;
    inherit (kde) plasmaTools kcmHosts;
    inherit (keybinds) volumeControlToggle;
    inherit (display) displayPower;
    inherit (video) videoProxy;
  };
}
