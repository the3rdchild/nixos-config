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
  # The same drop-in covers the other apps used to test the web app. Their
  # processes can end up in scopes named two different ways, and each app
  # needs a drop-in for both:
  #
  #   app-<desktop id>-<pid>.scope
  #     Created by the app itself or by whatever launched it. Electron and
  #     Chromium move their main process into one named after CHROME_DESKTOP:
  #     VS Code's main process and extension hosts sit in app-code-<pid>.scope,
  #     and the journal also shows app-obsidian- and app-org.chromium.Chromium-.
  #     KIO does the same for apps opened from Dolphin (app-org.kde.konsole-…).
  #
  #   app-Hyprland-<desktop id or command>-<8 hex>.scope
  #     From `uwsm app`, used by the caelestia launcher (patched in
  #     ./caelestia.nix), the SUPER+SHIFT+V bind and Dolphin's "Open with VS
  #     Code". uwsm escapes `-` inside the name as \x2d, so microsoft-edge
  #     becomes app-Hyprland-microsoft\x2dedge-…, and the drop-in directory
  #     has to spell it the same way, literal backslash included.
  #
  # For an Electron/Chromium app launched through uwsm, both scopes exist at
  # once, split by process. On 2026-09-16, VS Code started from SUPER+SHIFT+V
  # had its zygote and renderers (1.0 G) in app-Hyprland-code-<hex> and its
  # main process plus extension hosts (1.4 G) in app-code-<pid>, created a
  # second later. Each scope gets its own copy of the limit, so the effective
  # ceiling for such an app is the sum of the two. That was already true
  # before uwsm, when the SUPER+SHIFT+V wrapper scope and the self-created one
  # were both app-code-.
  #
  # Renaming app-code- to the uwsm name alone (2.4 of docs/uwsm-migration.md,
  # first try) left the main process with MemoryHigh=infinity. That is why the
  # old names stay next to the new ones.
  #
  # Edge has two desktop entries, microsoft-edge and com.microsoft.Edge, so
  # both uwsm names are covered. Edge's own self-created scope name has not
  # been observed here; app-microsoft-edge- assumes Chromium's CHROME_DESKTOP
  # naming. Firefox doesn't move itself into a scope, so app-firefox- only
  # matches KIO launches.
  #
  # Anything started with no scope at all (a bare keybind exec, a terminal
  # command) runs in its parent's cgroup and escapes these limits.
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

    # Self-created (Electron/Chromium) or KIO-launched scopes.
    ${dropIn "app-firefox-"} = limit "1G" "2G";
    ${dropIn "app-microsoft-edge-"} = limit "1G" "2G";
    ${dropIn "app-code-"} = limit "2G" "3.5G";

    # `uwsm app` scopes (launcher, SUPER+SHIFT+V, Dolphin's Open with VS Code).
    ${dropIn "app-Hyprland-firefox-"} = limit "1G" "2G";
    ${dropIn "app-Hyprland-microsoft\\x2dedge-"} = limit "1G" "2G";
    ${dropIn "app-Hyprland-com.microsoft.Edge-"} = limit "1G" "2G";
    ${dropIn "app-Hyprland-code-"} = limit "2G" "3.5G";
  };
}
