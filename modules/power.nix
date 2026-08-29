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
  # logind is the *only* thing arbitrating button/lid actions on this machine:
  # the session is Hyprland (see ./package.nix) and there is no hypridle.
  # plasma6 has since been dropped from ./service.nix, so powerdevil is not
  # installed at all any more. It never took effect here regardless (it only
  # runs inside a Plasma session), so the stale, hand-edited
  # ~/.config/powerdevilrc is now simply dead — everything below takes hold
  # unconditionally.
  #
  # Timed idle behaviour (dim / lock / suspend) is a separate matter: that
  # lives in the caelestia shell's idle monitors, configured declaratively in
  # ../home/caelestia.nix (general.idle in shell.json). logind's own
  # IdleAction stays "ignore" so it never double-sleeps underneath the shell.
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
    HandlePowerKey = "ignore";
    HandlePowerKeyLongPress = "ignore";

    # Dedicated sleep/hibernate keys do nothing.
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";

    # Lid behaviour is split by power source. logind picks one of these three
    # based on state, most specific first:
    #   HandleLidSwitchDocked        — docked, or >1 display connected
    #   HandleLidSwitchExternalPower — on AC
    #   HandleLidSwitch              — everything else (i.e. on battery)
    #
    # On AC and docked the lid still does nothing: that is the deliberate
    # "close it and keep the build running" behaviour this machine was set up
    # for, and on AC there is no cost to it.
    #
    # On battery it now suspends, which is the one case where doing nothing is
    # expensive. This battery has worn to 64.7% of design (33.99 Wh of 52.51),
    # so an idle-but-awake machine in a bag or between meetings burns a much
    # larger share of what is left than it used to. The shell's own idle timer
    # in ../home/caelestia.nix does eventually suspend on battery, but "lid
    # shut" is a far more definite signal of intent than an idle countdown,
    # and it fires immediately instead of after the timeout.
    #
    # Suspend here is real S3, not s2idle: /sys/power/mem_sleep reports
    # "s2idle [deep]", so the selected state is the one that actually cuts
    # power to the SoC rather than idling in it.
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";

    # No timed suspend/hibernate/shutdown from logind, ever. The shell's idle
    # monitor issues its own `systemctl suspend` on battery (see
    # ../home/caelestia.nix) — that path is unaffected by this switch.
    IdleAction = "ignore";
  };


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

  # Manual sleep is deliberately left working — SUPER+SHIFT+L in the caelestia
  # keybinds still suspends on purpose, as does the battery idle timer's
  # `systemctl suspend`. Only the *button/lid* paths are off, so sleep.target
  # / hibernate.target are not masked.
}
