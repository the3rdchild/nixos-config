{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.waybar = {
    enable = true;
    settings = {
      mainBar = {
        layer = "top";
        position = "top";
        height = 32;
        spacing = 4;

        modules-left = [ "hyprland/workspaces" "hyprland/window" ];
        modules-center = [ "clock" ];
        modules-right = [ "custom/kbd" "custom/fan" "pulseaudio" "bluetooth" "network" "cpu" "memory" "battery" "tray" ];

        "custom/fan" = {
          exec = "acer-ec waybar";
          return-type = "json";
          interval = 3;
          on-click = "acer-ec profile-cycle";
        };

        "custom/kbd" = {
          exec = "acer-ec waybar-kbd";
          return-type = "json";
          interval = 3;
          on-click = "acer-ec kbd toggle";
          on-scroll-up = "acer-ec kbd up";
          on-scroll-down = "acer-ec kbd down";
        };

        "hyprland/workspaces" = {
          format = "{id}";
          on-click = "activate";
          sort-by-number = true;
        };

        "hyprland/window" = {
          max-length = 50;
        };

        clock = {
          format = " {:%H:%M}";
          format-alt = " {:%Y-%m-%d %H:%M}";
          tooltip-format = "<big>{:%B %Y}</big>\n<tt>{calendar}</tt>";
        };

        cpu = {
          format = " {usage}%";
          interval = 2;
          tooltip = false;
        };

        memory = {
          format = " {}%";
          interval = 5;
        };

        battery = {
          states = { warning = 30; critical = 15; };
          format = "{icon} {capacity}%";
          format-charging = " {capacity}%";
          format-full = " {capacity}%";
          format-icons = [ "" "" "" "" "" ];
        };

        network = {
          format-wifi = " {signalStrength}%";
          format-ethernet = " connected";
          format-disconnected = " disconnected";
          tooltip-format = "{ifname}: {ipaddr}";
        };

        bluetooth = {
          format = " {status}";
          format-disabled = "";
          format-off = " off";
          format-on = "";
          format-connected = " {num_connections}";
          format-connected-battery = " {device_battery_percentage}%";
          tooltip-format = "{controller_alias}\t{controller_address}\n\n{num_connections} connected";
          tooltip-format-connected = "{controller_alias}\t{controller_address}\n\n{device_enumerate}";
          tooltip-format-enumerate-connected = "{device_alias}\t{device_address}";
          tooltip-format-enumerate-connected-battery = "{device_alias}\t{device_address}\t{device_battery_percentage}%";
          on-click = "blueman-manager";
        };

        pulseaudio = {
          format = "{icon} {volume}%";
          format-muted = " muted";
          format-icons = { default = [ "" "" "" ]; };
          on-click = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
          scroll-step = 5;
        };

        tray = {
          spacing = 8;
          icon-size = 16;
        };
      };
    };

    style = ''
      * {
        border: none;
        border-radius: 0;
        font-family: "JetBrainsMono Nerd Font", monospace;
        font-size: 13px;
        min-height: 0;
      }

      window#waybar {
        background-color: rgba(30, 30, 46, 0.92);
        color: #cdd6f4;
      }

      #workspaces button {
        padding: 0 8px;
        color: #6c7086;
        background: transparent;
      }

      #workspaces button.active {
        color: #89b4fa;
        border-bottom: 2px solid #89b4fa;
      }

      #workspaces button:hover {
        background: rgba(137, 180, 250, 0.1);
        color: #cdd6f4;
      }

      #window {
        color: #a6adc8;
        padding: 0 8px;
      }

      #clock {
        color: #89b4fa;
        font-weight: bold;
        padding: 0 12px;
      }

      #cpu { color: #a6e3a1; padding: 0 8px; }
      #memory { color: #f9e2af; padding: 0 8px; }
      #battery { color: #a6e3a1; padding: 0 8px; }
      #battery.warning { color: #f9e2af; }
      #battery.critical { color: #f38ba8; }
      #network { color: #89dceb; padding: 0 8px; }
      #bluetooth { color: #89b4fa; padding: 0 8px; }
      #bluetooth.disabled, #bluetooth.off { color: #6c7086; }
      #bluetooth.connected { color: #a6e3a1; }
      #pulseaudio { color: #cba6f7; padding: 0 8px; }
      #tray { padding: 0 8px; }

      #custom-fan { color: #94e2d5; padding: 0 8px; }
      #custom-fan.performance { color: #f9e2af; }
      #custom-fan.gaming { color: #f38ba8; }
      #custom-kbd { color: #b4befe; padding: 0 8px; }
      #custom-kbd.off { color: #6c7086; }
    '';
  };
}
