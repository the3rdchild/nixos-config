{ ... }:
{
  # ── Power button, lid, and idle behaviour.
  #
  # logind is the *only* thing arbitrating this on this machine: the session
  # is Hyprland (see ./package.nix), there is no hypridle, and the caelestia
  # shell has no idle handling of its own. plasma6 is enabled in ./service.nix
  # but powerdevil never runs outside a Plasma session, so its (mutable,
  # hand-edited) ~/.config/powerdevilrc has no effect here — everything below
  # takes hold unconditionally.
  #
  # NOTE: this is the settings.Login form, not the older per-key options
  # (services.logind.lidSwitch, .powerKey, …). Both still evaluate on this
  # nixpkgs, but the flat ones are the deprecated spelling and setting the
  # same key through both would conflict.
  services.logind.settings.Login = {
    # Tap the power button → clean shutdown. This matches the systemd default,
    # but it is pinned explicitly so it survives an upstream default change.
    HandlePowerKey = "poweroff";

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

    # No timed suspend/hibernate/shutdown, ever. IdleAction=ignore is already
    # the systemd default, but it is the single switch that would introduce an
    # automatic sleep here, so it is stated rather than assumed.
    IdleAction = "ignore";
  };

  # Manual sleep is deliberately left working — SUPER+SHIFT+L in the caelestia
  # keybinds still suspends on purpose. Only the *automatic* paths are off, so
  # sleep.target / hibernate.target are not masked.
}
