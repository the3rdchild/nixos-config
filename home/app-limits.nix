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
  # deliberately above Zen's observed steady state: a ceiling at ~4 GB would
  # hold it in permanent reclaim and feel worse than no limit at all.
  #
  # Swap is left uncapped on purpose. MemorySwapMax=0 removes the graceful
  # valve and turns every overshoot into an OOM kill.
  #
  # Changes here need `systemctl --user daemon-reload` and an app restart —
  # home-manager writes the file but does not reload the user manager for
  # plain config files.
  #
  # The same drop-in covers the other apps used to test the web app. The
  # caelestia launcher (patched in ./caelestia.nix), the SUPER+SHIFT+V bind
  # and Dolphin's "Open with VS Code" all start apps through `uwsm app`. That
  # names the scope
  #   app-<first XDG_CURRENT_DESKTOP>-<desktop id or command>-<8 hex>.scope
  # e.g. app-Hyprland-firefox-1a2b3c4d.scope. So the same trailing-dash prefix
  # trick matches every instance, as long as the name carries the "Hyprland-"
  # part. Two things to keep in mind:
  # - uwsm escapes `-` inside the ID as \x2d, so microsoft-edge becomes
  #   app-Hyprland-microsoft\x2dedge-…. The drop-in directory has to spell it
  #   the same way, literal backslash included.
  # - Edge has two desktop entries, microsoft-edge and com.microsoft.Edge, and
  #   the launcher lists both, so both get a drop-in.
  # Anything started with no scope at all (a bare keybind exec, a terminal
  # command) runs in its parent's cgroup and escapes these limits.
  #
  # Before 2.4 of docs/uwsm-migration.md the launcher created no scopes, so
  # the firefox and edge drop-ins (then app-firefox-, app-microsoft-edge-)
  # never matched anything.
  #
  # VS Code gets more headroom than the browsers: throttling it lands on the
  # TypeScript server and extension host, which shows up as typing lag. The
  # writer-hub `next dev` container lives in Docker's cgroup, not here.
  xdg.configFile = let
    limit = high: max: {
      text = ''
        [Scope]
        MemoryHigh=${high}
        MemoryMax=${max}
      '';
    };
    dropIn = scope: "systemd/user/${scope}.scope.d/50-memory.conf";
  in {
    ${dropIn "app-flatpak-app.zen_browser.zen-"} = limit "1.5G" "2.5G";
    ${dropIn "app-Hyprland-firefox-"} = limit "1G" "2G";
    ${dropIn "app-Hyprland-microsoft\\x2dedge-"} = limit "1G" "2G";
    ${dropIn "app-Hyprland-com.microsoft.Edge-"} = limit "1G" "2G";
    ${dropIn "app-Hyprland-code-"} = limit "2G" "3.5G";
  };
}
