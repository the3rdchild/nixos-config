{ pkgs, ... }:
{
  # ── Battery and power profiles.
  #
  # Both of these used to arrive for free from services.desktopManager.plasma6
  # (upower via `= config.powerManagement.enable`, ppd via mkDefault true).
  # Dropping plasma6 from ./service.nix took them with it, which left the
  # caelestia bar reporting "No battery detected" and its
  # performance/balanced/power-saver buttons inert. Declared explicitly now so
  # they no longer depend on a desktop manager we do not run.
  #
  # upower is what the shell reads BAT0 through — it talks the D-Bus interface,
  # not /sys/class/power_supply directly.
  services.upower.enable = true;

  # Power off at 12%. Nothing else on this machine suspends or powers down on
  # its own (see the logind block below and ../home/ii-session.nix), so this
  # is the one backstop against running the battery flat. System-level on
  # purpose: it still fires from the greeter, or with the shell crashed.
  #
  # UPower only acts while discharging, so on AC 12% means nothing. The three
  # levels must descend or upower rejects all of them; low/critical only set
  # UPower's own WarningLevel — the shell's notifications have their own
  # thresholds (25/20) in config.json.
  #
  # The shell's automaticSuspend (18%) had to go for this to work: a suspended
  # machine checks nothing, so it would have slept straight past 12% to zero.
  services.upower = {
    percentageLow = 20;
    percentageCritical = 15;
    percentageAction = 12;
    criticalPowerAction = "PowerOff";
  };

  # power-profiles-daemon is the other half: the shell's three profile buttons
  # are ppd's performance / balanced / power-saver. On this laptop that chain
  # continues into the EC — the acer driver bridges platform_profile, so those
  # three land on EC profile 4 / 2 / 1, which is exactly what the acer-fan-max
  # watcher in ./acer-ec.nix polls for. Without ppd running, nothing ever
  # writes the profile file and that watcher has nothing to react to.
  #
  # No conflict to worry about: there is no TLP or auto-cpufreq on this system.
  services.power-profiles-daemon.enable = true;

  # ── Power button, lid, and idle behaviour.
  #
  # logind is the *only* thing arbitrating button/lid *actions* on this
  # machine: the session is Hyprland (see ./package.nix), and plasma6 has
  # since been dropped from ./service.nix, so powerdevil is not installed at
  # all any more. The stale, hand-edited ~/.config/powerdevilrc is simply
  # dead — everything below takes hold unconditionally.
  #
  # The policy is: the machine never sleeps unless asked to. Only the screen
  # turns off — on lid close, and after idle on battery — and that half lives
  # in the ii session's Hyprland lid bind and hypridle.conf, both in
  # ../home/ii-session.nix (displayPower). logind's own IdleAction stays
  # "ignore" so nothing sleeps underneath that either.
  #
  # NOTE: this is the settings.Login form, not the older per-key options
  # (services.logind.lidSwitch, .powerKey, …). Both still evaluate on this
  # nixpkgs, but the flat ones are the deprecated spelling and setting the
  # same key through both would conflict.
  services.logind.settings.Login = {
    # Power button does nothing on a short press. The long-press hard cut is
    # unaffected: that's the Acer EC holding the rail down after ~4s, below
    # the OS entirely. logind's own long-press action is ignored too so it
    # can't race the EC with a soft poweroff mid-hold.
    #
    # Which leaves the EC cut as the only way out of a hung graphical session,
    # and a hard cut leaves the NTFS volumes dirty — ntfs3 then refuses to
    # mount /mnt/doc until chkdsk runs from Windows. See kernel.sysrq below.
    HandlePowerKey = "ignore";
    HandlePowerKeyLongPress = "ignore";

    # Dedicated sleep/hibernate keys do nothing.
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";

    # The lid does nothing to the system in any state — on AC, docked, and on
    # battery alike. logind picks one of these three by state (docked / on AC
    # / everything else), so all three have to say it.
    #
    # Battery used to suspend here. That was reverted deliberately: closing
    # the lid must never stop what is running. The cost is real — this battery
    # has worn to 64.7% of design (33.99 Wh of 52.51), and a lid-shut machine
    # in a bag now stays up until the screen-off/lock timers and, ultimately,
    # UPower's 12% poweroff above. The panel itself still goes dark: that is
    # the Hyprland lid bind in ../home/ii-session.nix, not logind.
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";

    # No timed suspend/hibernate/shutdown from logind, ever — and the ii
    # session's hypridle no longer suspends either.
    IdleAction = "ignore";
  };

  # ── Magic SysRq: a clean way out when the graphical session hangs.
  #
  # With both power-key actions ignored above, the only exit from a frozen
  # display (no greeter, no input) used to be the EC's ~4s hard cut, which
  # leaves /mnt/doc and /mnt/shared dirty. On 2026-09-16 that is exactly what
  # happened, and ntfs3 refused /mnt/doc until chkdsk ran from Windows.
  #
  # systemd's default is 16 (sync only). 176 = 16 sync + 32 remount read-only
  # + 128 reboot/poweroff, so holding Alt+SysRq (PrtSc) and pressing
  #   S (sync), U (remount ro), B (reboot)   — or O instead of B to power off
  # flushes and cleanly detaches every filesystem first. Deliberately not 1:
  # the process-killing and keyboard-raw keys stay off.
  boot.kernel.sysctl."kernel.sysrq" = 176;


  # ── Wi-Fi power saving.
  #
  # NetworkManager leaves this off by default; nothing in ./network.nix sets
  # it either way, so the AX210 has been running with PSM disabled. Turning it
  # on lets the radio sleep between beacons, which is where most of an idle
  # wifi link's power goes. The cost is a few ms of extra latency on the first
  # packet after an idle gap — invisible for browsing and ssh, and this is the
  # same default Windows ships on the same card.
  networking.networkmanager.wifi.powersave = true;

  # ── PCIe runtime power management.
  #
  # The kernel leaves power/control at "on" for most PCI devices unless
  # something sets it. TLP or `powertop --auto-tune` would normally be that
  # something, but neither is installed here (see the ppd note above — TLP and
  # power-profiles-daemon conflict, and ppd is what the caelestia bar drives).
  # So these rules do the same job for the handful of devices where it is
  # worth doing, and nothing else.
  #
  # Verified state before this rule (power/control per device):
  #   on  0000:04:00.0  Realtek RTL8168 Ethernet   — link DOWN, still powered
  #   on  0000:06:00.0  O2 Micro SD/MMC reader     — no card ever inserted
  #   on  0000:05:00.0  Intel AX210 Wi-Fi 6E
  #   on  0000:00:0a.0  Intel Platform Monitoring Technology
  #
  # The two NVMe controllers are deliberately NOT included. Their idle power
  # is already handled by APST (autonomous power state transitions, negotiated
  # by the drive itself), d3cold on top of that buys little, and one of them
  # carries the root filesystem — not somewhere to introduce resume latency
  # for a fraction of a watt.
  #
  # Matching on vendor/device rather than PCI slot: slots move when firmware
  # renumbers the bus, IDs do not.
  services.udev.extraRules = ''
    # O2 Micro OZ711 SD/MMC card reader. Nothing on this machine uses the SD
    # slot; the controller is simply powered up doing nothing.
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1217", ATTR{device}=="0x8621", ATTR{power/control}="auto"

    # Realtek RTL8111/8168 Gigabit Ethernet. The r8169 is the classic offender
    # here: it holds the link powered even with no cable attached, which is
    # this machine's normal state (wifi only).
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10ec", ATTR{device}=="0x8168", ATTR{power/control}="auto"

    # Intel Wi-Fi 6E AX210. Complements the NetworkManager powersave above:
    # that one is the radio's own PSM, this is the PCIe link underneath it.
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x2725", ATTR{power/control}="auto"

    # Intel Platform Monitoring Technology — telemetry block, no runtime user.
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x467d", ATTR{power/control}="auto"

    # ── Follow the AC adapter with the power profile (see the service below).
    ACTION=="change", SUBSYSTEM=="power_supply", KERNEL=="AC", RUN+="${pkgs.systemd}/bin/systemctl start --no-block ppd-follow-ac.service"
  '';

  # ── Switch power profile when the adapter comes and goes.
  #
  # power-profiles-daemon does not do this on its own. Under GNOME the shell
  # drives it; there is no GNOME here, and the caelestia bar only exposes the
  # three buttons for manual use — so unplugging the charger has so far left
  # the machine in whatever profile it was already in, which in practice is
  # "balanced" all day including on battery.
  #
  # power-saver is the meaningful one of the three on battery: it moves the
  # intel_pstate EPP from balance_performance to power, and takes the EC's
  # platform_profile down to "quiet" (profile 1), which lowers the fan curve
  # as well as the CPU. On AC it goes back to balanced rather than to
  # performance — performance pins the EC to profile 4, which ./acer-ec.nix
  # deliberately pairs with both fans at 100%.
  systemd.services.ppd-follow-ac = {
    description = "Match the power profile to AC adapter presence";
    # After, not Requires: if ppd is not up yet, the profile it starts in is
    # already the right one and there is nothing to correct.
    after = [ "power-profiles-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "ppd-follow-ac" ''
        online=$(cat /sys/class/power_supply/AC/online 2>/dev/null || echo 1)
        if [ "$online" = "0" ]; then
          target=power-saver
        else
          target=balanced
        fi
        # Never override a deliberate choice of "performance": if the user has
        # asked for it, plugging in should not silently drop them to balanced.
        cur=$(${pkgs.power-profiles-daemon}/bin/powerprofilesctl get 2>/dev/null || echo "")
        if [ "$cur" = "performance" ] && [ "$online" != "0" ]; then
          exit 0
        fi
        exec ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set "$target"
      '';
    };
  };

  # ── "Silent" mode: aggressive CPU power caps while power-saver is active.
  #
  # The three buttons on the caelestia bar are power-profiles-daemon's
  # performance / balanced / power-saver, and ppd bridges those into the EC as
  # platform_profile 4 / 2 / 1. What ppd does NOT do is limit the CPU: on this
  # machine power-saver only moves the intel_pstate EPP to "power" and leaves
  # everything else wide open —
  #
  #     no_turbo     = 0        turbo still live
  #     max_perf_pct = 100
  #     RAPL PL1/PL2 = 45 W / 115 W
  #
  # — so "power-saver" was costing far less than its name suggests. This
  # service closes that gap, and only for power-saver; balanced and
  # performance are left exactly as they were.
  #
  # Why cap power rather than force the fans down: fan1_duty_set is root-only
  # on purpose (see ../modules/acer-ec.nix — SCMD 0x68 carries both duties and
  # nothing on the EC side catches a CPU fan pinned low while load climbs).
  # Capping the package instead makes the CPU produce less heat, and the EC's
  # own quiet curve then slows the fan by itself. Silence as a consequence,
  # with the EC's thermal protection still fully in charge. The dGPU fan needs
  # no help at all: profile 1 already parks it (fan2_duty and fan2_rpm both
  # read 0 there).
  #
  # Event-driven, not polled. gdbus blocks on the ppd D-Bus signal, so this
  # costs nothing while the profile is not changing — which matters, since a
  # polling loop to save power would be self-defeating.
  systemd.services.power-profile-tuning = {
    description = "Cap CPU power while the power-saver profile is active";
    # graphical.target, not multi-user.target. ppd's own unit is ordered
    # After=multi-user.target, and a target is implicitly ordered after
    # everything it Wants — so wantedBy multi-user closed the loop
    # multi-user -> this -> ppd -> multi-user, and systemd broke it at every
    # boot by deleting this job. The service simply never ran.
    wantedBy = [ "graphical.target" ];
    after = [ "power-profiles-daemon.service" ];
    wants = [ "power-profiles-daemon.service" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
      # Uncapping on stop matters: without this, stopping or restarting the
      # unit would leave the machine pinned at 10 W until the next profile
      # change happened to come along.
      ExecStopPost = "${pkgs.writeShellScript "power-profile-tuning-release" ''
        B=/run/power-profile-tuning
        P=/sys/devices/system/cpu/intel_pstate
        R=/sys/class/powercap/intel-rapl:0
        # Fans back to the EC before the limits come off — same ordering rule
        # as restore() in the main script.
        echo 1 > /sys/kernel/acer_fanctl/fan_auto 2>/dev/null
        [ -f "$B/no_turbo" ]     && cat "$B/no_turbo"     > "$P/no_turbo" 2>/dev/null
        [ -f "$B/max_perf_pct" ] && cat "$B/max_perf_pct" > "$P/max_perf_pct" 2>/dev/null
        [ -f "$B/pl1" ] && cat "$B/pl1" > "$R/constraint_0_power_limit_uw" 2>/dev/null
        [ -f "$B/pl2" ] && cat "$B/pl2" > "$R/constraint_1_power_limit_uw" 2>/dev/null
        exit 0
      ''}";
      ExecStart = pkgs.writeShellScript "power-profile-tuning" ''
        set -u
        B=/run/power-profile-tuning
        P=/sys/devices/system/cpu/intel_pstate
        R=/sys/class/powercap/intel-rapl:0
        F=/sys/kernel/acer_fanctl

        # Silent targets. max_perf_pct is a percentage of the maximum turbo
        # ratio, so 30 lands around 1.3 GHz with turbo already disabled —
        # deliberately slow, which is the trade that was asked for.
        SILENT_PL1=10000000   # 10 W sustained
        SILENT_PL2=15000000   # 15 W burst; PL2 below PL1 would be meaningless
        SILENT_MAXPCT=30

        # Baseline is captured from the live machine rather than hardcoded, so
        # a firmware update that ships different stock limits is restored to
        # ITS values and not to yesterday's guess.
        mkdir -p "$B"
        if [ ! -e "$B/saved" ]; then
          cat "$P/no_turbo"     > "$B/no_turbo"     2>/dev/null || true
          cat "$P/max_perf_pct" > "$B/max_perf_pct" 2>/dev/null || true
          cat "$R/constraint_0_power_limit_uw" > "$B/pl1" 2>/dev/null || true
          cat "$R/constraint_1_power_limit_uw" > "$B/pl2" 2>/dev/null || true
          touch "$B/saved"
        fi

        # Never abort the loop on a rejected write. RAPL in particular may be
        # locked by firmware (the MSR has a lock bit that some Acer BIOSes
        # set); if it is, turbo and max_perf_pct still apply and the failure is
        # reported here instead of silently doing nothing.
        w() {
          if printf '%s' "$2" > "$1" 2>/dev/null; then
            return 0
          fi
          echo "power-profile-tuning: write refused: $1 <- $2" >&2
          return 1
        }

        WPID=$B/fan-waiter.pid

        profile_now() {
          ${pkgs.power-profiles-daemon}/bin/powerprofilesctl get 2>/dev/null || echo ""
        }

        stop_fan_waiter() {
          [ -f "$WPID" ] || return 0
          kill "$(cat "$WPID")" 2>/dev/null || true
          rm -f "$WPID"
        }

        start_fan_waiter() {
          stop_fan_waiter
          (
            prev=""
            n=0
            # Bounded: if the curve never settles (sustained load), latch
            # anyway after ~60 s rather than leaving the dGPU fan spinning
            # forever. The 10 W cap makes whatever duty it lands on safe.
            while [ "$n" -lt 12 ]; do
              sleep 5
              [ "$(profile_now)" = "power-saver" ] || exit 0
              cur=$(cat "$F/fan1_duty" 2>/dev/null) || exit 0
              [ -n "$prev" ] && [ "$cur" = "$prev" ] && break
              prev=$cur
              n=$((n + 1))
            done
            # Re-check once more: the profile may have changed during the last
            # sleep, and latching after a switch back to balanced would pin the
            # fans while the CPU runs uncapped.
            [ "$(profile_now)" = "power-saver" ] || exit 0
            w "$F/fan2_duty_set" 0
            echo "power-profile-tuning: dGPU fan parked (fan1_duty=$(cat $F/fan1_duty 2>/dev/null) fan1_rpm=$(cat $F/fan1_rpm 2>/dev/null) fan2_rpm=$(cat $F/fan2_rpm 2>/dev/null))"
          ) &
          echo $! > "$WPID"
        }

        silent() {
          w "$P/no_turbo" 1
          w "$P/max_perf_pct" "$SILENT_MAXPCT"
          w "$R/constraint_0_power_limit_uw" "$SILENT_PL1"
          w "$R/constraint_1_power_limit_uw" "$SILENT_PL2"

          # Park the dGPU fan — but only AFTER the caps above are in place,
          # and only once the EC has finished ramping.
          #
          # Ordering is the first half of the safety argument. SCMD 0x68
          # carries both fan duties, so writing fan2 latches fan1 at whatever
          # the EC's curve last set, taking the CPU fan off automatic control.
          # That is only acceptable because the package is already pinned to
          # 10 W by the time this runs: a 10 W package cannot outrun the duty
          # the quiet curve had already chosen.
          #
          # Waiting is the second half, and it was learned the hard way. ppd
          # writes platform_profile on every profile change, which makes the EC
          # re-apply its curve — and that curve ramps DOWN over roughly twenty
          # seconds (measured: duty 85 -> 80 -> 75 -> 71, settling at 71 with
          # the fan at ~1600 rpm). Latching immediately froze fan1 mid-ramp at
          # duty 86 with the curve then disabled, so it never came back down:
          # "silent" mode left the CPU fan stuck louder than balanced does.
          #
          # So: wait for fan1_duty to stop moving, then latch. Backgrounded
          # because apply() is called from the gdbus loop and must not block
          # it, and re-armed on every entry so a profile flip-flop cannot leave
          # two waiters racing.
          start_fan_waiter
          echo "power-profile-tuning: silent -> no_turbo=$(cat $P/no_turbo 2>/dev/null) max_perf_pct=$(cat $P/max_perf_pct 2>/dev/null) PL1=$(cat $R/constraint_0_power_limit_uw 2>/dev/null) PL2=$(cat $R/constraint_1_power_limit_uw 2>/dev/null) (dGPU fan queued)"
        }

        restore() {
          # Cancel any pending latch first: a waiter that fires after this
          # point would pin the fans while the CPU is running uncapped.
          stop_fan_waiter

          # Hand the fans back to the EC first, for the mirror image of the
          # reason above: uncapping to 45 W while fan1 is still latched low is
          # exactly the combination to avoid. fan_auto releases both.
          w "$F/fan_auto" 1

          [ -f "$B/no_turbo" ]     && w "$P/no_turbo"     "$(cat $B/no_turbo)"
          [ -f "$B/max_perf_pct" ] && w "$P/max_perf_pct" "$(cat $B/max_perf_pct)"
          [ -f "$B/pl1" ] && w "$R/constraint_0_power_limit_uw" "$(cat $B/pl1)"
          [ -f "$B/pl2" ] && w "$R/constraint_1_power_limit_uw" "$(cat $B/pl2)"
          echo "power-profile-tuning: restored stock limits"
        }

        apply() {
          prof=$(${pkgs.power-profiles-daemon}/bin/powerprofilesctl get 2>/dev/null || echo "")
          case "$prof" in
            power-saver) silent ;;
            "")          : ;;   # ppd not up yet; leave the machine alone
            *)           restore ;;
          esac
        }

        apply
        # Any property change on ppd wakes this; re-reading the profile is
        # cheaper than parsing gdbus's output format, and correct even if a
        # change is coalesced.
        ${pkgs.glib}/bin/gdbus monitor --system \
          --dest net.hadess.PowerProfiles \
          --object-path /net/hadess/PowerProfiles 2>/dev/null |
        while read -r _line; do
          apply
        done
      '';
    };
  };

  # Re-apply the silent tuning after a resume.
  #
  # The EC drops any manual fan duty and re-applies its own curve when the
  # machine comes back from suspend — the same behaviour ../modules/acer-ec.nix
  # documents for acer-fan-max. Without this, a manual suspend (SUPER+SHIFT+L)
  # on battery and the resume after it would silently leave the dGPU fan
  # spinning again while the profile still said power-saver.
  #
  # NOT powerManagement.resumeCommands. That option still exists and still
  # type-checks on this nixpkgs, but nothing consumes it any more: there is no
  # post-resume unit in the built system, and a value set there appears in no
  # unit or sleep hook at all. It fails silently, which is the worst way for a
  # safety re-assertion to fail — hence this explicit unit instead.
  #
  # WantedBy + After on the sleep targets is the standard idiom for "run on the
  # way back up": systemd starts units ordered After= a sleep target once the
  # system has resumed, which is exactly what NixOS's own post-resume used to do.
  #
  # try-restart rather than a bespoke re-apply path: a restart runs
  # ExecStopPost (fans back to the EC, stock limits) and then ExecStart
  # (re-read the profile, re-apply only if it is still power-saver), reusing
  # the ordering guarantees already written into both halves. No-op when the
  # unit is not running.
  systemd.services.power-profile-tuning-resume = {
    description = "Re-apply CPU/fan power caps after resume";
    after = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    wantedBy = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl try-restart power-profile-tuning.service";
    };
  };

  # Manual sleep is deliberately left working — SUPER+SHIFT+L in the ii
  # keybinds still suspends on purpose. Only the *button/lid/idle* paths are
  # off, so sleep.target / hibernate.target are not masked.
}
