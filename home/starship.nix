{
  config,
  pkgs,
  lib,
  ...
}:
{
  programs.starship = {
    enable = true;
    enableFishIntegration = true;

    settings = {
      format = lib.concatStrings [
        "[](color_slate)"
        "$os"
        "[](bg:color_dusk fg:color_slate)"
        "$directory"
        "[](fg:color_dusk bg:color_stone)"
        "$git_branch"
        "[](fg:color_stone bg:color_sand)"
        "$git_status"
        "[](fg:color_sand bg:color_cream)"
        "$nix_shell"
        "[](fg:color_cream bg:color_peach)"
        "$cmd_duration"
        "[](fg:color_peach bg:color_clay)"
        "$time"
        "[](fg:color_clay)"
      ];

      palette = "sandstone";
      palettes.sandstone = {
        color_fg_light = "#f7efd2";   # For dark segments (slate, dusk, stone)
        color_fg_dark  = "#2e3b46";   # For light segments (sand → clay)

        color_slate = "#475c6c";
        color_dusk  = "#697178";      # blend: slate → stone
        color_stone = "#8a8583";
        color_sand  = "#eed7a1";
        color_cream = "#f7efd2";
        color_peach = "#e2bd9a";      # blend: cream → clay
        color_clay  = "#a67352";
      };

      os = {
        disabled = false;
        style = "bg:color_slate bold fg:color_fg_light";
        symbols = {
          NixOS = " ";
        };
      };

      directory = {
        style = "bold fg:color_fg_light bg:color_dusk";
        format = "[ $path ]($style)";
        truncation_length = 3;
      };

      git_branch = {
        symbol = "";
        style = "bg:color_stone";
        format = "[[ $symbol $branch ](bold fg:color_fg_light bg:color_stone)]($style)";
      };

      git_status = {
        style = "bg:color_sand bold fg:color_fg_light";
        format = "[$all_status$ahead_behind]($style)";
      };

      nix_shell = {
        format = "[ via nix $name ]($style)";
        style = "bg:color_cream bold fg:color_fg_dark";
      };

      cmd_duration = {
        format = "[ 󰔛 $duration ]($style)";
        disabled = false;
        style = "bg:color_peach bold fg:color_fg_dark";
        show_notifications = false;
        min_time_to_notify = 60000;
      };

      time = {
        disabled = false;
        time_format = "%R";
        style = "bg:color_clay";
        format = "[[   $time ](bold fg:color_fg_light bg:color_clay)]($style)";
      };

      line_break = {
        disabled = false;
      };

      character = {
        disabled = false;
        success_symbol = "[  ](bold fg:color_slate)";
        error_symbol = "[  ](bold fg:color_clay)";
      };
    };
  };
}