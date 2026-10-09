{
  config,
  pkgs,
  lib,
  ...
}: {
  # Caelestia ships a fish/config.fish, but home-manager already generates
  # ~/.config/fish/config.fish from the options below — symlinking theirs on
  # top would collide. So its contents are ported here instead, which also
  # keeps the nixos-rebuild aliases that predate the migration.
  programs.fish = {
    enable = true;

    shellAliases = {
      grep = "grep --color=auto";
      # The config lives in the git repo at /mnt/doc/config; /etc/nixos is no
      # longer a second copy to keep in sync (the two silently diverged once).
      nrs = "sudo nixos-rebuild switch --flake '/mnt/doc/config#noouoops'";
      ncg = "nix-collect-garbage -d";
      nrst = "sudo nixos-rebuild switch --flake '/mnt/doc/config#noouoops' --show-trace";
      cbe = "sudo nix-collect-garbage -d && sudo nix profile wipe-history --profile /nix/var/nix/profiles/system";
    };

    # Inherited from the caelestia dots' fish/config.fish.
    shellAbbrs = {
      lg = "lazygit";
      gd = "git diff";
      ga = "git add .";
      gc = "git commit -am";
      gl = "git log";
      gs = "git status";
      gst = "git stash";
      gsp = "git stash pop";
      gp = "git push";
      gpl = "git pull";
      gsw = "git switch";
      gsm = "git switch main";
      gb = "git branch";
      gbd = "git branch -d";
      gco = "git checkout";
      gsh = "git show";
      sonora = "cd /mnt/doc/local-web-player && npm run start";

      l = "ls";
      ll = "ls -l";
      la = "ls -a";
      lla = "ls -la";
    };

    # starship, direnv and zoxide are home-manager modules here (see the
    # bottom of this file and ./starship.nix) and inject their own fish
    # hooks, so nothing below may init them by hand — that would source each
    # hook twice.
    #
    # Scope worth knowing: this configures ~/.config/fish, which the
    # illogical-impulse session does NOT read — it ships its own config.fish
    # under the alternate config root (see ./ii-session). So this is the
    # fish you get on a TTY, over SSH, or anywhere XDG_CONFIG_HOME is unset,
    # and the two are deliberately kept saying the same things.
    interactiveShellInit = ''
      alias ls='eza --icons --group-directories-first -1'

      # Replay the palette the shell generates from the current wallpaper.
      # This is how foot (and any other terminal) picks up the scheme —
      # there are no colours in foot.ini itself. Same file the session's own
      # config.fish reads; it used to be caelestia's equivalent under
      # ~/.local/state/caelestia, which stopped being written when that
      # session was dropped.
      cat ~/.local/state/quickshell/user/generated/terminal/sequences.txt 2> /dev/null

      # Lets foot jump between prompts (ctrl+shift+z / ctrl+shift+x).
      function mark_prompt_start --on-event fish_prompt
          echo -en "\e]133;A\e\\"
      end
    '';
  };

  # `cd` is remapped to zoxide, matching the session's own config.fish.
  programs.zoxide = {
    enable = true;
    options = [ "--cmd cd" ];
  };
  programs.direnv.enable = true;

  home.packages = [ pkgs.eza ];
}
