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
    };
  };

  programs.lazygit = {
    enable = true;
  };
}
