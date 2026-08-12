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

  fanSysfs = "/sys/kernel/acer_fanctl";

  # ── Make EC profile 4 actually mean "both fans flat out".
  #
  # profile 4 ("gaming") selects the EC's most aggressive fan CURVE, not a duty
  # floor. Measured at 80 C on this laptop it settles at dut1=dut2=71 — 28% —
  # so "performance" in the desktop applet sounded like it should be loud and
  # was not. Pinning both duties to 255 is what closes that gap: RPM1 goes
  # 2111 -> 4595, RPM2 1521 -> 3083.
  #
  # Reached via profile rather than via power-profiles-daemon directly: the
  # driver already bridges platform_profile, so ppd's performance/balanced/
  # power-saver land on EC profile 4/2/1 on their own. Watching the profile
  # file instead of the D-Bus property keeps this independent of who did the
  # switching — applet, powerprofilesctl, or a bare write to sysfs.
  #
  # Polled, not evented: these are plain kobject attributes and the driver
  # never calls sysfs_notify, so there is nothing to wait on. Polling buys
  # self-healing anyway, which a one-shot latch would not have — see below.
  acer-fan-max = pkgs.writeShellScriptBin "acer-fan-max" ''
    S=${fanSysfs}
    PIN_PROFILE=4

    # The EC re-asserts its curve only when the profile VALUE changes; sending
    # the profile that is already active is a no-op. So bounce through a
    # neighbour and come straight back. (The driver's fan_auto does the same
    # thing — open-coded here because ExecStop must not depend on a module new
    # enough to have that attribute.)
    release() {
      cur=$(cat "$S/profile" 2>/dev/null) || return 0
      case "$cur" in
        1) other=2 ;;
        2|3|4) other=1 ;;
        *) return 0 ;;
      esac
      echo "$other" > "$S/profile" 2>/dev/null || return 0
      echo "$cur" > "$S/profile" 2>/dev/null || return 0
    }

    if [ "''${1-}" = release ]; then
      release
      exit 0
    fi

    while :; do
      # Missing sysfs is not an error: the module may not be loaded yet, or may
      # be mid-reload after a kernel update. Just keep looking.
      if [ -r "$S/profile" ] && [ "$(cat "$S/profile")" = "$PIN_PROFILE" ]; then
        # Re-assert rather than latch. A manual duty is dropped whenever the EC
        # re-applies a curve, and that happens on resume and on any outside
        # profile write — neither of which raises an event we could hook. So
        # compare against the live duties every pass and only write when they
        # have drifted, which keeps this idempotent and quiet.
        if [ "$(cat "$S/fan1_duty")" != 255 ] || [ "$(cat "$S/fan2_duty")" != 255 ]; then
          # Order does not matter: each store re-sends the sibling's current
          # duty, so the pair converges on (255, 255) either way.
          echo 255 > "$S/fan1_duty_set"
          echo 255 > "$S/fan2_duty_set"
        fi
      fi
      sleep 3
    done
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

  # Runs as root because fan1_duty_set is root-only and stays that way — see
  # the tmpfiles rules below for why. ExecStop releases the pin so stopping or
  # restarting the unit does not leave the fans locked at maximum.
  systemd.services.acer-fan-max = {
    description = "Pin both fans to maximum while the EC is in profile 4";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      ExecStart = "${acer-fan-max}/bin/acer-fan-max";
      ExecStop = "${acer-fan-max}/bin/acer-fan-max release";
      RemainAfterExit = false;
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

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
