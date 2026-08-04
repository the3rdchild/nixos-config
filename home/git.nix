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

  programs.lazygit = {
    enable = true;
  };
}
