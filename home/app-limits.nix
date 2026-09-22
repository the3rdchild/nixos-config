{ ... }:
{
  # ── Per-app resource ceilings.
  #
  # Companion to ../modules/memory.nix, which covers the system-wide half
  # (zram, swappiness, page-cluster) and carries the full diagnosis.
  #
  # Zen is the largest single consumer on this machine — observed growing from
  # 3.8 GB to 4.8 GB over one session, against 15 GB of RAM shared with VS Code
  # and the quickshell session. It is installed as a Flatpak
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
  # The same drop-in covers the other apps used to test the web app. How an
  # app's processes are grouped depends on who launched it, and each way
  # gives the unit a different name. These are the ones actually observed
  # here (journal and live units, 2026-09-16):
  #
  #   app-Hyprland-<desktop id or command>-<8 hex>.scope    [Scope]
  #     `uwsm app`, used by the caelestia session's launcher, its SUPER+SHIFT+V
  #     bind and Dolphin's "Open with VS Code".
  #
  #     DEAD as of the caelestia drop: ../modules/package.nix now sets
  #     withUWSM = false, and the surviving session never ran under uwsm
  #     anyway, so nothing creates these scopes and the drop-ins named after
  #     them attach to nothing. They are kept rather than deleted because
  #     putting that session under uwsm is the one change that brings the VS
  #     Code cap back, and this is the shape it has to match when it does.
  #
  #   app-<CHROME_DESKTOP id>-<pid>.scope                   [Scope]
  #     Created by Electron/Chromium apps themselves, which move their main
  #     process there a second after start, whoever launched them. VS Code:
  #     app-code-<pid>, holding the main process and extension hosts. Edge
  #     doesn't set CHROME_DESKTOP and falls back to Chromium's default ID,
  #     app-org.chromium.Chromium-<pid>, holding its main browser process.
  #     The journal also shows app-obsidian-. That Chromium name is generic:
  #     any Chromium app without CHROME_DESKTOP would land there and get Edge's
  #     limit. None has, so far.
  #
  #   app-<desktop id>@<32 hex>.service                     [Service]
  #     KIO, for anything opened from Dolphin ("Open with", open terminal).
  #     These are transient *services*, not scopes, so they need .service.d
  #     drop-ins with a [Service] section. The app-org.kde.konsole-<pid>.scope
  #     scopes older journals show are from the Plasma session, gone since
  #     August.
  #
  # So an Electron/Chromium app is split across two units at once: the
  # launcher's (uwsm scope or KIO service) with its renderers, GPU and
  # utility processes, and its own scope with the main process. Each unit
  # gets its own copy of the limit, so the effective ceiling for such an app
  # is the sum of the two.
  #
  # uwsm and KIO both escape `-` inside the ID as \x2d (microsoft-edge becomes
  # app-Hyprland-microsoft\x2dedge-… and app-microsoft\x2dedge@….service).
  # The drop-in directory has to spell it the same way, literal backslash
  # included. Both escaped forms were checked against real units with a
  # temporary runtime drop-in. Edge has two desktop entries, microsoft-edge and
  # com.microsoft.Edge, so both IDs are covered.
  #
  # Nothing observed creates app-firefox-<n>.scope or
  # app-microsoft-edge-<n>.scope (Firefox never moves itself into a scope;
  # Edge's own scope has the Chromium name above). The drop-ins by those names
  # that used to be here matched nothing, and are gone.
  #
  # Anything started with no unit of its own (a bare keybind exec, a command
  # in a terminal) runs in its parent's cgroup and escapes these limits.
  #
  # VS Code gets more headroom than the browsers: throttling it lands on the
  # TypeScript server and extension host, which shows up as typing lag. The
  # writer-hub `next dev` container lives in Docker's cgroup, not here.
  xdg.configFile = let
    limit = section: high: max: {
      text = ''
        [${section}]
        MemoryHigh=${high}
        MemoryMax=${max}
      '';
    };
    scope = name: "systemd/user/${name}.scope.d/50-memory.conf";
    service = name: "systemd/user/${name}.service.d/50-memory.conf";

    browser = limit "Scope" "1G" "2G";
    browserSvc = limit "Service" "1G" "2G";
    editor = limit "Scope" "2G" "3.5G";
    editorSvc = limit "Service" "2G" "3.5G";
  in {
    # flatpak runs every app in its own scope, whoever launched it.
    ${scope "app-flatpak-app.zen_browser.zen-"} = limit "Scope" "1.5G" "2.5G";

    # `uwsm app`: launcher, SUPER+SHIFT+V, Dolphin's Open with VS Code.
    ${scope "app-Hyprland-firefox-"} = browser;
    ${scope "app-Hyprland-microsoft\\x2dedge-"} = browser;
    ${scope "app-Hyprland-com.microsoft.Edge-"} = browser;
    ${scope "app-Hyprland-code-"} = editor;

    # Self-created by Electron/Chromium (main process).
    ${scope "app-code-"} = editor;
    ${scope "app-org.chromium.Chromium-"} = browser; # Edge

    # KIO transient services (opened from Dolphin).
    ${service "app-firefox@"} = browserSvc;
    ${service "app-microsoft\\x2dedge@"} = browserSvc;
    ${service "app-com.microsoft.Edge@"} = browserSvc;
    ${service "app-code@"} = editorSvc;
  };
}
