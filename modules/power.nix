{ ... }:
{
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

    # Closing the lid does nothing, on every power source. logind picks one of
    # these three based on state, most specific first:
    #   HandleLidSwitchDocked        — docked, or >1 display connected
    #   HandleLidSwitchExternalPower — on AC
    #   HandleLidSwitch              — everything else (i.e. on battery)
    #
    # Only HandleLidSwitch actually needs overriding (NixOS defaults it to
    # "suspend"; the other two already fall through to it when unset). They are
    # all pinned anyway so no future default can reintroduce a suspend on one
    # power source but not the other.
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";

    # No timed suspend/hibernate/shutdown from logind, ever. The shell's idle
    # monitor issues its own `systemctl suspend` on battery (see
    # ../home/caelestia.nix) — that path is unaffected by this switch.
    IdleAction = "ignore";
  };

  # Manual sleep is deliberately left working — SUPER+SHIFT+L in the caelestia
  # keybinds still suspends on purpose, as does the battery idle timer's
  # `systemctl suspend`. Only the *button/lid* paths are off, so sleep.target
  # / hibernate.target are not masked.
}
