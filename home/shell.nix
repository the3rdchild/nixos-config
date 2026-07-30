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

    # From caelestia's fish/config.fish.
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

      l = "ls";
      ll = "ls -l";
      la = "ls -a";
      lla = "ls -la";
    };

    # Caelestia's config.fish inits starship, direnv and zoxide by hand. Here
    # those are home-manager modules (see the bottom of this file and
    # ./starship.nix) which inject their own fish hooks — repeating them
    # would source each hook twice.
    interactiveShellInit = ''
      # Caelestia's `ls`. Replaces the old `ls --color=auto` alias.
      alias ls='eza --icons --group-directories-first -1'

      # Replay the palette caelestia generates from the current wallpaper.
      # This is how foot (and any other terminal) picks up the scheme —
      # there are no colours in foot.ini itself.
      cat ~/.local/state/caelestia/sequences.txt 2> /dev/null

      # Lets foot jump between prompts (ctrl+shift+z / ctrl+shift+x).
      function mark_prompt_start --on-event fish_prompt
          echo -en "\e]133;A\e\\"
      end

      # Machine-local additions, written by hand. home/caelestia.nix creates
      # this as an empty file so the source never errors.
      set -q XDG_CONFIG_HOME && set -l cConf $XDG_CONFIG_HOME/caelestia || set -l cConf $HOME/.config/caelestia
      source $cConf/user-config.fish 2> /dev/null
    '';
  };

  # `cd` is remapped to zoxide, matching caelestia's config.fish.
  programs.zoxide = {
    enable = true;
    options = [ "--cmd cd" ];
  };
  programs.direnv.enable = true;

  home.packages = [ pkgs.eza ];
}
