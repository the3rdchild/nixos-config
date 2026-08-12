{ config, inputs, pkgs, ... }:

let
  acer-ec = config.boot.kernelPackages.callPackage "${inputs.acer-ec}/nix/default.nix" { };

  kbdDev = "acer_ec::kbd_backlight";

  # brightnessctl has no toggle; -s saves the current level, -r restores it.
  acer-kbd-toggle = pkgs.writeShellScriptBin "acer-kbd-toggle" ''
    dev=${kbdDev}
    bctl="${pkgs.brightnessctl}/bin/brightnessctl -d $dev"
    if [ "$($bctl get)" -gt 0 ]; then
      $bctl -s set 0
    else
      $bctl -r || $bctl set 255
    fi
  '';
in
{
  boot.extraModulePackages = [ acer-ec ];
  boot.kernelModules = [ "acer_ec_core" "acer_fanctl" "acer_ec_kbd" ];

  # PowerDevil drives external-monitor brightness over DDC/CI, which needs
  # /dev/i2c-* plus group access. Without this only the built-in panel appears.
  hardware.i2c.enable = true;

  boot.extraModprobeConfig = ''
    # acer-ec — module load order + default profile
    softdep acer_fanctl pre: acer_ec_core
    softdep acer_ec_kbd pre: acer_ec_core
    options acer_fanctl profile_param=2
  '';

  environment.systemPackages = [
    acer-ec
    acer-kbd-toggle
    pkgs.lm_sensors
    pkgs.brightnessctl
  ];

  # Fan profile lives in a raw kobject, not a udev device, so tmpfiles has to
  # relax it. Lets the waybar module switch profiles without a sudo prompt.
  #
  # fan1_duty_set is deliberately NOT here. SCMD 0x68 carries both duties and
  # the EC honours them indefinitely on this firmware, so a write to fan1 can
  # stop the CPU fan outright with nothing to catch it — that one stays root.
  # fan2 is the GPU fan and is safe to hand to the desktop; fan_auto is the
  # way back from any manual duty, so it has to be at least as reachable as
  # the writes it undoes.
  systemd.tmpfiles.rules = [
    "z /sys/kernel/acer_fanctl/profile 0664 root video -"
    "z /sys/kernel/acer_fanctl/fan2_duty_set 0664 root video -"
    "z /sys/kernel/acer_fanctl/fan_auto 0664 root video -"
  ];

  # Let members of "video" set keyboard backlight without root.
  #
  # UPower caches an fd to the brightness file at startup, so reloading the
  # module (kernel updates, manual insmod) leaves it holding a stale handle and
  # Plasma's slider silently stops working. Restarting it on device add fixes
  # that for good.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="leds", KERNEL=="${kbdDev}", \
      RUN+="${pkgs.coreutils}/bin/chgrp video /sys/class/leds/%k/brightness", \
      RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/leds/%k/brightness", \
      RUN+="${pkgs.systemd}/bin/systemctl --no-block try-restart upower.service"
  '';

  environment.etc."sensors.d/acer-ec.conf".text = ''
    chip "acer_ec-*"
        label temp1 "EC Temp"
        label fan1 "CPU Fan"
        label fan2 "GPU Fan"
  '';
}
