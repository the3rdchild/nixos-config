{ config, lib, pkgs, ... }:

let
  # The driver tree lives in-repo under Reference/, so this is a plain relative
  # path rather than a flake input. It used to be `inputs.acer-ec`, a
  # `path:/mnt/doc/acer-ec` input pointing outside the repo — which broke the
  # moment that directory moved, and which also meant every driver edit needed
  # a `nix flake update acer-ec` before it was picked up. A relative path has
  # neither problem: it moves with the repo and edits take effect immediately.
  #
  # nix/default.nix does `src = lib.cleanSource ../.`, which resolves relative
  # to its own file, so it still captures exactly the acer-ec subtree.
  acer-ec = config.boot.kernelPackages.callPackage
    ../Reference/acer-aspire-A715-79G/acer-ec/nix/default.nix
    { };

  kbdDev = "acer_ec::kbd_backlight";

  # ── Keyboard backlight colour.
  #
  # "R G B", each 0-255, written to the LED's multi_intensity on boot. The EC
  # holds the colour itself and nothing on the Linux side used to set it, so it
  # simply kept whatever was written last — by Acer Control Center under
  # Windows, or by a previous boot — and reverted to the firmware default
  # whenever the EC lost power. That is why it turned red on its own. Setting
  # it here makes the colour survive power cycles.
  #
  # null leaves the EC's current colour alone (the driver skips its colour
  # command entirely while multi_intensity is 0 0 0), which is the old
  # brightness-only behaviour.
  kbdColour = "0 0 255";

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
  ppctl = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl";

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

    # ── Carry an EC profile chosen outside ppd back into ppd.
    #
    # The bridge only runs one way: ppd -> platform_profile -> EC. A profile
    # picked in the acer-ec web UI (or a bare sysfs write) moves the EC and
    # its fan curve but leaves ppd where it was, so profile 4 ran with ppd
    # still on "balanced" — EPP balance_performance instead of performance,
    # and the bar showing the wrong button.
    #
    # 1/2/4 map onto ppd's power-saver/balanced/performance, and ppd writes
    # the same value straight back to the EC, so there is no loop. 3 has no
    # ppd equivalent: handing it to ppd would push the EC to 2 or 4 and undo
    # the choice, so ppd is left alone and the EPP is written directly. 2 also
    # writes it, because a 3 -> 2 move never changes ppd and nothing else
    # would take the EPP back down.
    sync_ppd() {
      case "$1" in
        1) ppd=power-saver; epp= ;;
        2) ppd=balanced;    epp=balance_performance ;;
        3) ppd=;            epp=performance ;;
        4) ppd=performance; epp=performance ;;
        *) return 0 ;;
      esac
      if [ -n "$ppd" ] && [ "$(${ppctl} get 2>/dev/null)" != "$ppd" ]; then
        ${ppctl} set "$ppd" 2>/dev/null || true
      fi
      if [ -n "$epp" ]; then
        for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
          echo "$epp" > "$f" 2>/dev/null || true
        done
      fi
    }

    # The first reading is synced only when it is not the boot default. At
    # boot the EC comes up on profile_param=2 before ppd restores its saved
    # profile; syncing that 2 would override the user's last choice with
    # "balanced". Anything else means the unit was restarted (nixos-rebuild
    # switch) under an already-chosen profile, which must still reach ppd.
    last=$(cat "$S/profile" 2>/dev/null || echo "")
    if [ -n "$last" ] && [ "$last" != 2 ]; then
      sync_ppd "$last"
    fi

    while :; do
      cur=$(cat "$S/profile" 2>/dev/null || echo "")
      if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
        sync_ppd "$cur"
        last=$cur
      fi
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
      # Poll cadence is split by whether there is anything to do. In the
      # pinned profile the fans must be re-asserted promptly, so 3 s stands.
      # Outside it — which is nearly all of the time, since profile 4 is the
      # gaming profile — this loop was still waking every 3 s to fork two
      # `cat`s and compare a string it had already seen, around 28 000 wakeups
      # a day for no observable work. 15 s there is still far faster than a
      # human can switch profiles and notice the fans lagging.
      if [ "$(cat "$S/profile" 2>/dev/null)" = "$PIN_PROFILE" ]; then
        sleep 3
      else
        sleep 15
      fi
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
  # multi_intensity gets the same treatment as brightness so colour is settable
  # without root, and is seeded from kbdColour on device add. ATTR{} assignment
  # runs before the RUN+= chmod, so the seed does not depend on the permission
  # change having landed — udev writes it as root either way.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="leds", KERNEL=="${kbdDev}", \
      ${lib.optionalString (kbdColour != null) ''ATTR{multi_intensity}="${kbdColour}", \
      ''}RUN+="${pkgs.coreutils}/bin/chgrp video /sys/class/leds/%k/brightness", \
      RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/leds/%k/brightness", \
      RUN+="${pkgs.coreutils}/bin/chgrp video /sys/class/leds/%k/multi_intensity", \
      RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/leds/%k/multi_intensity", \
      RUN+="${pkgs.systemd}/bin/systemctl --no-block try-restart upower.service"
  '';

  environment.etc."sensors.d/acer-ec.conf".text = ''
    chip "acer_ec-*"
        label temp1 "EC Temp"
        label fan1 "CPU Fan"
        label fan2 "GPU Fan"
  '';
}
