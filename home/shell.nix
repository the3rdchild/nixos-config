{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.fish = {
    enable = true;

    shellAliases = {
      ls = "ls --color=auto";
      grep = "grep --color=auto";
      nrs = "sudo nixos-rebuild switch --flake '/etc/nixos#noouoops'";
      ncg = "nix-collect-garbage -d";
      nrst = "sudo nixos-rebuild switch --flake '/etc/nixos#noouoops' --show-trace";
      cbe = "sudo nix-collect-garbage -d && sudo nix profile wipe-history --profile /nix/var/nix/profiles/system";
    };

    interactiveShellInit = ''
      starship init fish | source
    '';
  };
}
