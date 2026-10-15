{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.git = {
    enable = true;
    settings = {
     user = {
        name = "the3rdchild";
        email = "ytcrash555@gmail.com";
     };
     init.defaultBranch = "main";
     # Selalu pakai SSH untuk GitHub, walaupun remote-nya di-clone via HTTPS
     url."git@github.com:".insteadOf = "https://github.com/";
    };
  };

  # GitHub CLI — buat buka PR dari mesin ini. Login sekali manual:
  # `gh auth login` (token disimpan di ~/.config/gh/hosts.yml, bukan di repo)
  programs.gh = {
    enable = true;
    settings.git_protocol = "ssh";
  };

  programs.lazygit = {
    enable = true;
  };
}
