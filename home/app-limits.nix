{ ... }:
{
  # ── Per-app resource ceilings.
  #
  # Companion to ../modules/memory.nix, which covers the system-wide half
  # (zram, swappiness, page-cluster) and carries the full diagnosis.
  #
  # Zen is the largest single consumer on this machine — observed growing from
  # 3.8 GB to 4.8 GB over one session, against 15 GB of RAM shared with VS Code
  # and the caelestia shell. It is installed as a Flatpak
  # (app.zen_browser.zen), and flatpak already runs every app in its own
  # transient scope under app.slice, so the limits attach to a cgroup that
  # exists rather than needing a wrapper script or a rewritten .desktop entry.
  #
  # The directory name is not a typo, and the trailing dash is load-bearing.
  # systemd reads drop-ins from unit names truncated at each dash, so
  # "app-flatpak-app.zen_browser.zen-.scope.d" matches every launch despite
  # the random suffix flatpak appends. Verified against a live instance with
  # `systemctl --user show <scope> -p DropInPaths`.
  #
  # This must be a user unit path: /etc/systemd/user is a generated store
  # symlink that environment.etc cannot write into. ~/.config/systemd/user is
  # also the higher-precedence location, and Zen is a per-user flatpak anyway.
  #
  # MemoryHigh is the knob that does the work — it throttles and reclaims under
  # pressure without killing anything. MemoryMax is only a backstop, set well
  # clear of High so it stays a last resort rather than the normal path. It is
  # deliberately above Zen's observed steady state: a ceiling at ~5 GB would
  # hold it in permanent reclaim and feel worse than no limit at all.
  #
  # Swap is left uncapped on purpose. MemorySwapMax=0 removes the graceful
  # valve and turns every overshoot into an OOM kill.
  #
  # Changes here need `systemctl --user daemon-reload` and a Zen restart —
  # home-manager writes the file but does not reload the user manager for
  # plain config files.
  xdg.configFile."systemd/user/app-flatpak-app.zen_browser.zen-.scope.d/50-memory.conf".text = ''
    [Scope]
    MemoryHigh=6G
    MemoryMax=8G
  '';
}
