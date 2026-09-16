# Hyprland → UWSM

**Status (2026-09-16): migration complete and verified.** Everything is
applied and checked in a live session: Tier 1, 2.1, 2.2 (shell, polkit,
cliphist), 2.3 and 2.4. Left open on purpose:
- the optional parts of 2.2 (keyring, mpris-proxy, geoclue, trash), which
  gain little
- dropping the `QT_QPA_PLATFORMTHEME` dots patch (2.1), which the plain
  fallback session still needs
- the KIO `.service.d` memory drop-ins (2.4), added after the last
  verification and not yet seen matching a Dolphin launch

The first login also turned up two things the plan missed. **Logout through
`Session.Terminate` hangs SDDM**, and **UWSM starts XDG autostart entries**.
Both are covered in
[First login findings](#first-login-findings-2026-09-16). This is the
assessment and step list for moving the Hyprland session from a plain SDDM
launch to [UWSM](https://github.com/Vladimir-csp/uwsm) (Universal Wayland
Session Manager). When a step lands, update this document instead of leaving
it describing the old state.

Related: [`caelestia.md`](caelestia.md) for how the desktop is wired together.

---

## TL;DR

- **Switching is cheap:** two lines, one rebuild, one test login. The old
  `Hyprland` session stays in SDDM as the fallback.
- **Doing it properly is half a day to a day.** Most of that is moving
  environment variables and autostart programs out of the upstream caelestia
  dots and into systemd/UWSM, which adds patches to `home/caelestia.nix`.
- **Recommended order:** Tier 1 now → environment variables (2.1) and the
  theme-sync services (2.3) → autostart (2.2) only if you want what systemd
  gives you for those processes.

---

## Why bother

UWSM runs the compositor as a systemd user unit and brings up the standard
targets (`graphical-session-pre.target`, `graphical-session.target`,
`wayland-session@Hyprland.target`). What this machine gets from that:

| Plain "Hyprland" session (before, and the fallback)                                                                                                                  | With UWSM                                                                                                                                     |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `graphical-session.target` is `inactive`. Anything bound to it never starts, which is why `kde-color-sync` and `gtk-theme-sync` hang off `default.target`. | The target is reached. Home-manager services with a`graphical-session` default work unchanged.                                              |
| Autostart is`hl.exec_cmd` in `execs.lua`. A crash stays dead, and output goes nowhere.                                                                           | Autostart can be user units with`Restart=`, ordering, and logs in `journalctl --user`.                                                    |
| Only the VS Code bind is wrapped in `systemd-run`. Apps from the caelestia launcher run in no scope, so the limits in `home/app-limits.nix` don't reach them. | `uwsm app --` launches into a scope under `app-graphical.slice`, whose name the drop-ins can match. The launcher is patched to use it (2.4). |
| Logout kills the logind session; nothing is stopped in order.                                                                                                        | `uwsm stop` stops the graphical targets in order. (Killing the logind session is *not* a clean alternative here. See the findings below.) |
| XDG autostart (`/etc/xdg/autostart`, `~/.config/autostart`) is never processed.                                                                                  | `xdg-desktop-autostart.target` runs it. This helps, but it also starts anything that was sitting there unnoticed.                           |

---

## Current state (verified 2026-09-16)

| Piece                | Where                                                                                        | Notes                                                                                                                                                                                                                                                                                           |
| -------------------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hyprland enabled     | `modules/package.nix`                                                                      | `programs.hyprland.enable = true`, `withUWSM = true`. Hyprland 0.56.0 (Lua config), uwsm 0.26.6. D-Bus was already `broker`, which `programs.uwsm` forces, so that part is a no-op.                                                                                                     |
| Default session      | `modules/sddm.nix`                                                                         | `services.displayManager.defaultSession = "hyprland-uwsm"`. SilentSDDM greeter.                                                                                                                                                                                                               |
| Environment          | dots`hypr/hyprland/env.lua` + `uwsm/env`, `uwsm/env-hyprland` (`home/caelestia.nix`) | `hl.env` for Qt/GDK/SDL/Electron backends, `XCURSOR_*`, `XDG_*`. `QT_QPA_PLATFORMTHEME` is patched to `kde` in `home/caelestia.nix`. The uwsm files carry the same values (minus `XDG_*`) for the systemd activation environment; see 2.1.                                        |
| Autostart            | dots `hypr/hyprland/execs.lua` + user units (`home/caelestia.nix`) | On `hyprland.start`: gnome-keyring (secrets), `trash-empty 30`, `hyprctl setcursor` + 2× `gsettings` cursor, geoclue demo agent, `mpris-proxy`. The polkit-gnome agent, 2× `wl-paste --watch cliphist store` and the shell are also still there, wrapped so they run **only outside UWSM** (`unless-uwsm`, `caelestia-shell-up`). Under UWSM those three run as the `polkit-gnome`, `cliphist`/`cliphist-images` and `caelestia` user units instead. gammastep is patched out. |
| Shell service        | `home/caelestia.nix` | `programs.caelestia.systemd.enable = true`, `KillMode=process`. The `caelestia` unit starts from `graphical-session.target`, so under UWSM only; the plain session starts the shell from `execs.lua` as before. See 2.2. |
| Session-mode daemons | `home/qt.nix`, `home/themes.nix` | `kde-color-sync`, `gtk-theme-sync`: `WantedBy = default.target`, kept on purpose so they run in both sessions. The comments say so (2.3). |
| Logout               | caelestia shell`SessionManager`, `shell.json`                                            | The shell's default`logout` alias is logind `Session.Terminate` over D-Bus, which hangs SDDM (see findings). `home/caelestia.nix` merges `session.commands.logout = ["uwsm", "stop"]` into `shell.json` (activation `caelestiaShellLogout`). No keybind in the dots exits Hyprland. |
| XDG autostart        | `/run/current-system/sw/etc/xdg/autostart`, `~/.config/autostart`                        | Runs under UWSM only. blueman-applet and warp-taskbar start from here. The geoclue demo agent does too, then exits because`execs.lua` already started one. polkit-gnome and onboard entries were removed (see findings).                                                                      |
| App launch           | caelestia shell `launcher/services/Apps.qml`, `home/caelestia.nix`, `home/mime.nix` | Launcher, SUPER+SHIFT+V and Dolphin's "Open with VS Code" go through `uwsm app`, into `app-Hyprland-<id>-<hex>.scope` in `app-graphical.slice` (2.4). Other shell execs and plain keybind execs still run unscoped. |

---

## Tier 1 — switch the session (~30 min) — applied; login and logout verified

```nix
# modules/package.nix
programs.hyprland = {
  enable = true;
  package = pkgs.hyprland;
  withUWSM = true;              # enables programs.uwsm
};

# modules/sddm.nix
services.displayManager.defaultSession = "hyprland-uwsm";
```

Where the session entry comes from is easy to get wrong:

- The Hyprland **package** ships both `hyprland.desktop` and
  `hyprland-uwsm.desktop` (`providedSessions = [ "hyprland" "hyprland-uwsm" ]`).
  The UWSM one is named **"Hyprland (uwsm-managed)"** and runs
  `uwsm start -e -D Hyprland hyprland.desktop`, so the compositor is still
  launched through `hyprland.desktop`'s `start-hyprland`.
- `withUWSM` only sets `programs.uwsm.enable`: the uwsm binary, its user units
  (`wayland-wm@`, `wayland-session-bindpid@`, …) and D-Bus broker. It does
  **not** add a session of its own (`programs.uwsm.waylandCompositors` stays
  empty). What it does matter for: `hyprland-uwsm.desktop` has
  `TryExec=uwsm`, so without it the greeter hides that entry.
- The plain **Hyprland** entry stays in the greeter as the rollback.

Nothing else has to change for this tier: `execs.lua` still runs, `env.lua`
still applies to everything Hyprland starts, and the two theme daemons still
start from `default.target`.

### Verify

```fish
sudo nixos-rebuild switch --flake /mnt/doc/config#noouoops
# log out, pick "Hyprland (uwsm-managed)" in SilentSDDM, log in

systemctl --user is-active graphical-session.target   # expect: active
systemctl --user status 'wayland-wm@*'                 # the compositor unit
uwsm check is-active && echo ok
systemctl --user show-environment | grep -E 'WAYLAND_DISPLAY|XDG_CURRENT_DESKTOP|QT_QPA|XCURSOR'
```

Then test the things most likely to break:

- [x] SilentSDDM lists the new session and picks it as the default
- [x] Caelestia shell up; bar, launcher, notifications
- [x] Polkit prompt appears (e.g. mount a disk)
- [x] Clipboard history (SUPER+V) records text and images
- [x] Qt apps follow dark/light (`kde` platform theme); GTK too
- [x] Cursor theme/size correct in both Wayland and XWayland apps
- [x] Screen sharing / portals (Hyprland portal) in the browser
- [x] **Logout from the caelestia session menu returns to SDDM**, and a
  fresh login from there starts cleanly (no leftover `wayland-wm@*`
  unit). Verified 2026-09-16 with the menu running `uwsm stop`: the units
  stopped in order, `wayland-wm@hyprland.desktop.service` exited cleanly
  with no coredump, SDDM logged `sddm-helper exited successfully`, and the
  greeter was back within ~4s. To confirm the command is in place:
  `python3 -c "import json;print(json.load(open('$HOME/.config/caelestia/shell.json'))['session'])"`
  (jq is not installed).
- [x] `systemctl --user --failed` is empty after login

**Rollback:** pick "Hyprland" at the greeter, or revert the two lines. The
menu's logout does nothing in that session, because there is no UWSM session
to stop. No clean way to log out of it has been verified, so leave it with
the menu's reboot or shutdown. Do **not** use `loginctl terminate-session`.

### First login findings (2026-09-16)

**`loginctl terminate-session` / `Session.Terminate` leaves SDDM hung.**
This was hit from the plain Hyprland session, while switching to UWSM:

- logind kills every process in the session scope, including `sddm-helper`.
  SDDM logs `Auth: sddm-helper (… --start …/start-hyprland …) crashed (exit code 1)` and then never starts the greeter again. The screen stays on a
  bare VT with a blinking cursor and takes no input.
- `start-hyprland` also dumped core (SIGABRT from `std::thread::join` inside
  its own signal handler). That is noise next to the SDDM problem.
- `HandlePowerKey = "ignore"` (`modules/power.nix`) meant the short press did
  nothing, so the only way out was the EC's hard power cut. That left the
  ext4 root needing journal recovery, the ESP with its dirty bit set, and
  `/mnt/doc` (ntfs3) dirty and refused at mount until `chkdsk /f` ran from
  Windows. `git fsck` on this repo (which lives on `/mnt/doc`) was clean
  afterwards.

Under UWSM the same call would kill `sddm-helper` the same way, because the
helper is still in the session scope. That is why the caelestia menu's logout
is now `uwsm stop`. `modules/power.nix` also sets `kernel.sysrq = 176`: if the
display hangs again, hold Alt+SysRq and press S, U, B (or O) to reboot or
power off cleanly. Before that, try CTRL+ALT+F3, log in, and run
`sudo systemctl restart display-manager`.

**UWSM runs XDG autostart.** Once `graphical-session.target` is reached,
`xdg-desktop-autostart.target` starts every applicable `.desktop` entry. The
plain session never did this, so entries that had been sitting there unused
came to life:

| Entry                                   | Source                                         | What happened                                                                                          | Action                                                                                    |
| --------------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| `onboard`                             | `home/onboard.nix` (`~/.config/autostart`) | Started the X11 on-screen keyboard, which wvkbd (SUPER+SHIFT+K) replaced                               | Module removed                                                                            |
| `polkit-gnome-authentication-agent-1` | `polkit_gnome` in system packages            | Lost the race to the`execs.lua` agent ("An authentication agent already exists"), left a failed unit | Package dropped from`modules/hyprland-desktop.nix`; `execs.lua` runs it by store path |
| `blueman`                             | `services.blueman`                           | blueman-applet in the tray                                                                             | Kept                                                                                      |
| `com.cloudflare.WarpTaskbar`          | cloudflare-warp                                | warp-taskbar in the tray                                                                               | Kept                                                                                      |
| `geoclue-demo-agent`                  | `services.geoclue2`                          | "Another instance … is running", exits 0                                                              | Kept; harmless, goes away with 2.2                                                        |
| `xdg-user-dirs`                       | `xdg-user-dirs`                              | One-shot update                                                                                        | Kept                                                                                      |

---

## Tier 2 — use it properly (half a day to a day)

### 2.1 Environment variables → UWSM env files — applied, verified

Under UWSM, `hl.env` only reaches processes Hyprland spawns. Units in the user
manager (portals, D-Bus-activated apps, anything from 2.2) get the systemd
activation environment instead, which UWSM builds from its env files. A
variable that exists only in `env.lua` shows up as Qt/cursor theming that is
right in some apps and wrong in others.

Now in `home/caelestia.nix`, next to `caelestia/hypr-vars.lua`:

```nix
"uwsm/env".text = ''
  export QT_QPA_PLATFORMTHEME=kde
  export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
  export QT_AUTO_SCREEN_SCALE_FACTOR=1
  export GDK_BACKEND=wayland,x11
  export QT_QPA_PLATFORM='wayland;xcb'
  export SDL_VIDEODRIVER=wayland,x11,windows
  export CLUTTER_BACKEND=wayland
  export ELECTRON_OZONE_PLATFORM_HINT=auto
  export _JAVA_AWT_WM_NONREPARENTING=1
'';

"uwsm/env-hyprland".text = ''
  export XCURSOR_THEME=${lib.escapeShellArg config.themes.activeCursor}
  export XCURSOR_SIZE=${toString cursorSize}
'';
```

- uwsm sources `uwsm/env` for every session, then `uwsm/env-<name>` for each
  desktop name, lowercased (`libexec/uwsm/prepare-env.sh`). Both run as POSIX
  `sh`, after `/etc/profile`, so `environment.sessionVariables` still arrive.
- Values mirror `env.lua` exactly, including upstream's
  `SDL_VIDEODRIVER=wayland,x11,windows`. Two different values would make an
  app's environment depend on who launched it.
- `XDG_CURRENT_DESKTOP` / `XDG_SESSION_TYPE` / `XDG_SESSION_DESKTOP` are set
  by UWSM from the session; they are deliberately not in the files.
- The cursor theme is the same `config.themes.activeCursor` that
  `hypr-vars.lua` uses, and the size is a shared `cursorSize` binding in the
  file's `let` block, so the two can't drift apart. uwsm's hyprland plugin
  already marks `XCURSOR_THEME`/`XCURSOR_SIZE` for export on finalize.
- `env.lua` is left as it is (same values, set twice). **Still open:** once a
  UWSM login is confirmed, the `QT_QPA_PLATFORMTHEME` patch in
  `home/caelestia.nix` can go, which takes one `--replace-fail` off the dots.
  Not before: the plain fallback session reads only `env.lua`.

Check with `systemctl --user show-environment` after login.

### 2.2 Autostart → systemd user units — shell, polkit, cliphist applied, units verified

Each `execs.lua` entry, and the unit that could replace it:

| `execs.lua`                                         | Replacement                                        | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ----------------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gnome-keyring-daemon --start --components=secrets` | `services.gnome-keyring` (HM)                    | WantedBy`graphical-session-pre.target`. Set `components = [ "secrets" ]`. Check it doesn't collide with a PAM-started keyring.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| polkit-gnome agent                                    | `services.polkit-gnome` (HM)                     | WantedBy`graphical-session.target`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 2×`wl-paste --watch cliphist store`                | `services.cliphist` (HM), `allowImages = true` | Target defaults to`wayland.systemd.target` (graphical-session).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `mpris-proxy`                                       | `services.mpris-proxy` (HM)                      | Bound to the user`bluetooth.target`, not the session — starts when a BT device connects.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| geoclue demo agent                                    | small custom user unit                             | Only useful if gammastep comes back. It could simply be dropped.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `caelestia shell -d`                                | `programs.caelestia.systemd.enable = true`       | Target defaults to`wayland.systemd.target`. **Must** be removed from `execs.lua` at the same time, or two shells run (see the comment in `home/caelestia.nix`). `keybinds.lua` touches the shell in **three** places, and all three need patching: CTRL+SUPER+SHIFT+R (`qs -c caelestia kill`, kill only), CTRL+SUPER+ALT+R (kill, then `caelestia shell -d`) and `kbRestoreLock` (`caelestia shell -d`, then lock). `kbRestoreLock` matters most: it is the way back when the shell crashes while locked, and left alone it would start a second shell outside the unit. The `qs -c caelestia kill` half was already broken on NixOS, in both sessions (see What was applied). |
| `trash-empty 30`                                    | user timer, or leave in`execs.lua`               | One-shot; nothing to supervise.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `hyprctl setcursor` + `gsettings` cursor          | leave in`execs.lua`                              | Needs the running compositor; cheap and idempotent.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

**Cost:** `execs.lua` is upstream-verbatim apart from the existing patches.
Each line removed is another `--replace-fail` in `home/caelestia.nix`, and
each one is a place a `nix flake update caelestia-dots` can fail the build.
That failure is loud, not silent, but it's still maintenance. Converting the
shell, polkit and cliphist gets most of the benefit; the rest can stay.

#### What was applied

The shell, the polkit agent and both cliphist watchers are now user units.
The rest of `execs.lua` is untouched. Everything is in `home/caelestia.nix`.

- **Units:** `programs.caelestia.systemd.enable = true`,
  `services.polkit-gnome` (plus `Restart=on-failure`, which upstream lacks)
  and `services.cliphist` with `allowImages = true`. All four units are
  WantedBy/PartOf `graphical-session.target`.
- **The fallback session keeps working.** The plain "Hyprland" session never
  reaches `graphical-session.target`, so deleting the `execs.lua` lines would
  leave it with no bar, launcher, session menu, polkit prompts or clipboard
  history. The lines are gated instead:
  - `uwsm/env-hyprland` exports `CAELESTIA_UWSM=1`. uwsm sources that file
    only for its own Hyprland session and unsets it on stop, so the marker is
    present exactly when running under UWSM.
  - `unless-uwsm <cmd>` exits 0 under UWSM and runs the command otherwise.
    It wraps the polkit and both `wl-paste` lines.
  - `caelestia-shell-up` runs `systemctl --user reset-failed` and then
    `start --no-block caelestia.service` under UWSM, or
    `caelestia shell -d` otherwise. It replaces the shell start in
    `execs.lua` and both starts in `keybinds.lua` (CTRL+SUPER+ALT+R,
    `kbRestoreLock`). `reset-failed` is there so `kbRestoreLock` still
    recovers a shell that crashed often enough to hit the start limit.
  - The patch cost is 3 new `--replace-fail` anchors, and the existing
    polkit path patch changed.
- **`KillMode=process` on `caelestia`.** Upstream's unit keeps the default
  `control-group`. Apps opened from the launcher, session menu or dashboard
  are children of the shell and live in its cgroup, so any restart (crash,
  `systemctl --user restart caelestia`, or home-manager's sd-switch after a
  unit change) would kill all of them. Under `execs.lua` they lived in the
  compositor's cgroup, where a shell restart didn't touch them. 2.4
  (launching apps into their own scopes) would make this unnecessary.
  The cost: the shell's own `nmcli monitor` helpers (`services/Nmcli.qml`, and
  `services/VPN.qml` while a VPN provider is selected) survive it too.
  quickshell exits on SIGTERM without stopping its `Process` children, so
  every restart and every logout left one orphan in the cgroup. Three had
  piled up by the time this was noticed, and each lives until a
  NetworkManager event makes its next write hit a closed pipe.
  `ExecStopPost=caelestia-reap-nmcli-monitors` runs after the main process is
  gone and kills only `nmcli monitor` processes left in the unit's cgroup.
  Tested in a transient scope: the fake `nmcli monitor` was killed, and the
  `nmcli dev wifi` and `sleep` decoys survived.
- **cliphist parity:** `extraOptions = [ ]`. The module's default
  `-max-dedupe-search 10 -max-items 500` would otherwise differ from the
  `execs.lua` lines, which use cliphist's built-in 100 / 750, and both
  sessions share one history database. The HM text unit watches without
  `--type text`. An image copy can reach both units, and cliphist's dedupe
  drops the duplicate.
- **Kill binds fixed (found 2026-09-16, after the rollout).** CTRL+SUPER+SHIFT+R
  and CTRL+SUPER+ALT+R both kill with upstream's `qs -c caelestia kill`, and
  that has never worked here, in either session. `-c` looks for
  `~/.config/quickshell/caelestia/`, but the shell runs from its store path,
  so qs prints `Could not find "caelestia" config directory` and kills
  nothing. The kill bind did nothing, and the restart bind only "started" a
  shell that was still running. Both now go through `caelestia-shell-kill`
  (`--replace-fail 'qs -c caelestia kill'`, 2 occurrences). Under UWSM it runs
  `systemctl --user stop caelestia`: the unit is left inactive, and
  `Restart=on-failure` doesn't undo it. `stop` blocks until the process is
  gone, so the restart bind's `; sleep .1; caelestia-shell-up` starts a fresh
  shell. Otherwise it runs `caelestia shell -k`, i.e. `caelestia-shell kill`,
  whose wrapper passes the store path.

**Rolling it out.** home-manager uses `sd-switch`, and
`graphical-session.target` is already active in the running UWSM session. So
`nixos-rebuild switch` starts the four units immediately, next to the
`execs.lua` copies that are already running (two shells, a failing duplicate
polkit agent). Log out and back in from the menu right after switching.
On 2026-09-16 this went as expected. `polkit-gnome.service` failed to
register against the `execs.lua` agent five times, hit `start-limit-hit`,
and came up normally after the re-login.

**Verify** (after the fresh login):

```fish
systemctl --user is-active caelestia polkit-gnome cliphist cliphist-images   # 4× active
qs list --all | grep -c '^Instance'                  # 1
pgrep -c -f 'wl-paste .*--watch'                     # 2 (both from the units)
systemctl --user show caelestia -p KillMode          # KillMode=process
systemctl --user --failed                            # empty
```

- [x] Units active, one shell (`qs list`), the shell's `MainPID` in
      `caelestia.service`'s cgroup, one `wl-paste` per unit and one polkit agent
      (all from units, none from `execs.lua`), `KillMode=process`, no failed
      units. Verified 2026-09-16.
- [x] Bar, launcher, notifications work
- [x] CTRL+SUPER+ALT+R restarts the shell. The first test failed: the bind
      did nothing, because of the broken `qs -c caelestia kill` above. After
      the `caelestia-shell-kill` fix it works in a single press (it is
      kill-then-start, and does not need CTRL+SUPER+SHIFT+R first). The
      journal showed `Stopping` → `Stopped` → `Started` about 110 ms apart,
      twice, 2026-09-16.
- [x] Apps opened from the launcher stay open across that restart. Since
      2.4 they aren't in the shell's cgroup at all.
- [x] CTRL+SUPER+SHIFT+R kills the shell, and `systemctl --user is-active
      caelestia` stays `inactive` until CTRL+SUPER+ALT+R.
- [x] After a restart, `pgrep -c -x nmcli` is 1, or 2 with a VPN provider
      selected (the reaper). Verified 2026-09-16: 1 after the restart following
      the switch, and no `left-over process` warnings. For these binds, use the physical SUPER key: the
      CTRL+ESC → SUPER chord (`modules/hyprland-desktop.nix`) releases CTRL,
      so it can't produce CTRL+SUPER combos.
- [x] Polkit prompt appears; SUPER+V history records text and images
- [x] Logout from the menu still returns to SDDM. `uwsm stop` is forked from
      the unit-run shell, so it sits in `caelestia.service`'s cgroup while
      that unit is being stopped. Verified 2026-09-16: systemd logged
      `caelestia.service: Unit process … (python3.14) remains running after
      unit stopped` for it (the `uwsm stop` process, kept alive by
      `KillMode=process`), uwsm finished with `Sent stop job`, and SDDM logged
      `sddm-helper exited successfully`. With the default `control-group`
      that process would have been killed mid-logout.
- [ ] Plain "Hyprland" session still gets the shell, polkit and clipboard
      history from `execs.lua` (optional; leave it via the menu's reboot)

### 2.3 Theme daemons → `graphical-session.target` — applied (re-commented)

`kde-color-sync` (`home/qt.nix`) and `gtk-theme-sync` (`home/themes.nix`)
work fine as they are, so this is mostly about keeping the comments true.
Either:

- move them to `graphical-session.target`, with `PartOf` the same target so
  they stop at logout, and rewrite the comments; or
- keep `default.target` and just rewrite the comments. They don't need a
  compositor, so starting early is harmless.

**Chosen: keep `default.target`.** The plain "Hyprland" session is still
offered in the greeter as the fallback, and it never reaches
`graphical-session.target`. Moving the units there would silently drop dark/
light following in that session. The comments in both files now describe
both sessions. Revisit if the fallback session is ever removed.

### 2.4 App launches into scopes — applied, verified

Before this step, the caelestia launcher called `DesktopEntry.execute()`, a
bare detached QProcess. Launched apps lived in the shell's cgroup
(`caelestia.service` under UWSM, the login session scope otherwise), outside
the `app-*.scope` drop-ins in `home/app-limits.nix`. Only the SUPER+SHIFT+V
bind and Dolphin's "Open with VS Code" made a scope, with a hand-rolled
`systemd-run --user --scope --unit=app-code-…`. Electron and Chromium apps
were partly covered anyway: they move their main process into their own
`app-<CHROME_DESKTOP id>-<pid>.scope`. That's where VS Code's main process and
extension hosts live, and `app-code-` matched it.

#### What was applied

- **Launcher** (`home/caelestia.nix`, `shellSrc`): `Apps.qml` gets 2
  `--replace-fail` anchors. Both branches (plain, and `runInTerminal` via
  caelestia's `wrap_term_launch.sh`) now exec
  `uwsm app -a <entry.id> -- <entry.command…>`. The command is the one
  Quickshell already parsed; only process placement changes, and `-a` puts
  the desktop ID in the unit name. uwsm is referenced by store path, so the
  launcher doesn't depend on `withUWSM` staying on.
- **VS Code bind and Dolphin service menu:** `uwsm app -- code` (`… code %F`
  in `home/mime.nix`).
- **Drop-ins added** (`home/app-limits.nix`): uwsm names scopes
  `app-<first XDG_CURRENT_DESKTOP>-<id or command>-<8 hex>.scope` in
  `app-graphical.slice`, and escapes `-` inside the name as `\x2d`. The
  old names **stay**, because an Electron/Chromium app launched through uwsm
  ends up in two scopes at once:

  | Drop-in dir | Matches |
  |---|---|
  | `app-Hyprland-code-.scope.d` | uwsm scope for `code` (bind, service menu, launcher): zygote and renderers |
  | `app-Hyprland-firefox-.scope.d` | Firefox from the launcher |
  | `app-Hyprland-microsoft\x2dedge-.scope.d`, `app-Hyprland-com.microsoft.Edge-.scope.d` | Edge from the launcher, both desktop entries; literal backslash |
  | `app-code-.scope.d` | VS Code's self-created `app-code-<pid>.scope`: main process and extension hosts |
  | `app-org.chromium.Chromium-.scope.d` | Edge's self-created scope. Edge doesn't set `CHROME_DESKTOP`, so Chromium's default ID is used. It holds the main browser process. The name is generic: any Chromium app without `CHROME_DESKTOP` lands here too |
  | `app-firefox@.service.d`, `app-microsoft\x2dedge@.service.d`, `app-com.microsoft.Edge@.service.d`, `app-code@.service.d` | KIO launches from Dolphin, which are transient **services** `app-<id>@<uuid>.service`, so these use `[Service]` sections |
  | `app-flatpak-app.zen_browser.zen-.scope.d` | Unchanged: `flatpak run` moves Zen into its own `app-flatpak-…` scope, whoever launched it |

  The old `app-firefox-` and `app-microsoft-edge-` **scope** drop-ins are
  gone. Nothing observed creates those names: Firefox never moves itself into
  a scope, Edge's own scope uses the Chromium name, and KIO makes services.
  KIO also stopped making `app-<id>-<pid>.scope`; the
  `app-org.kde.konsole-<pid>.scope` entries in the journal date from the
  Plasma session (August). Both escaped forms, `app-Hyprland-microsoft\x2dedge-…scope`
  and `app-microsoft\x2dedge@….service`, were checked against real units
  with a temporary runtime drop-in, and matched.

  **First try got this wrong.** It renamed `app-code-` to
  `app-Hyprland-code-` and dropped the old names. After the switch, VS Code
  from SUPER+SHIFT+V showed its zygote and renderers (1.0 G) correctly capped
  in `app-Hyprland-code-452a65ec.scope`. Its main process and extension hosts
  (1.4 G) had moved themselves into `app-code-43824.scope` (43824 = main PID,
  `CHROME_DESKTOP=code.desktop`) with `MemoryHigh=infinity`. Journal history
  shows the same self-created pattern for `app-obsidian-` and
  `app-org.chromium.Chromium-`. Each scope carries its own copy of the limit,
  so the effective ceiling for such an app is the sum of the two. That was
  already true before, when the SUPER+SHIFT+V wrapper scope was `app-code-`
  too.

- **Tested before switching:**
  - A dummy `uwsm app -a microsoft-edge -- sleep` became
    `app-Hyprland-microsoft\x2dedge-<hex>.scope`, and a test drop-in under
    `$XDG_RUNTIME_DIR/systemd/user/app-Hyprland-microsoft\x2dedge-.scope.d/`
    showed up in its `DropInPaths` with `MemoryHigh` applied. The test
    drop-in was removed afterwards.
  - `uwsm app` has no active-session check, so the plain fallback session
    gets the same scopes. `app-graphical.slice` is `PartOf`
    `graphical-session.target`, so under UWSM launched apps are also stopped
    cleanly at logout.
  - `uwsm app` added about 100 ms per launch here; `app2unit` about 40 ms.
    uwsm was kept anyway: it's already installed, and one tool is used
    everywhere.
- **Not covered:** other exec paths inside the shell (session commands,
  recordings list player and explorer, calculator terminal, launcher
  actions) and plain keybind execs from `keybinds.lua` (terminal, file
  manager, …). `KillMode=process` on `caelestia` therefore stays.

**Rolling it out.** The shell package changes, so sd-switch restarts
`caelestia` (apps survive, `KillMode=process`). home-manager does not reload
the user manager for plain drop-in files, so run
`systemctl --user daemon-reload` after switching. Otherwise new scopes won't
see the renamed drop-ins.

**Verify:**

```fish
# after opening VS Code (SUPER+SHIFT+V) and Firefox or Edge from the launcher
systemctl --user list-units --plain --no-legend 'app-Hyprland-*'
for u in (systemctl --user list-units --plain --no-legend 'app-Hyprland-*' | awk '{print $1}')
    systemctl --user show $u -p Id -p DropInPaths -p MemoryHigh
end
```

- [x] Launcher apps land in `app-Hyprland-<id>-….scope`, not in
      `caelestia.service`. After the tests that unit held only quickshell and
      one `nmcli monitor`.
- [x] VS Code: both `app-Hyprland-code-<hex>` and `app-code-<pid>` show
      `MemoryHigh` 2 G after the fix. On the first try only the uwsm scope did;
      see the note above.
- [x] Edge from the launcher: `app-Hyprland-microsoft\x2dedge-<hex>` and its
      self-created `app-org.chromium.Chromium-<pid>` both show 1 G. The
      Chromium one showed `infinity` until its drop-in was added.
- [x] Firefox from the launcher: `app-Hyprland-firefox-<hex>` shows 1 G.
- [x] Zen (`app-flatpak-app.zen_browser.zen-…`) still shows 1.5 G.
- [x] A `Terminal=true` entry (btop, micro) still opens in foot.
- [x] Dolphin → "Open with VS Code" works. The journal shows KIO's
      service-menu unit handing off to `uwsm app -- code`.
- [ ] Dolphin → "Open with" Firefox, Edge or VS Code: the KIO
      `app-<id>@<uuid>.service` shows a finite `MemoryHigh` (drop-ins added
      after the rest of this list was verified).

All verified 2026-09-16 unless marked open.

---

## Risks and open questions

| Risk                                                                      | Likelihood                                     | Mitigation                                                                                                                                             |
| ------------------------------------------------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Env var only in`env.lua` → wrong theming in systemd/D-Bus-started apps | Medium                                         | 2.1; compare`show-environment` with `env` in a terminal.                                                                                           |
| Double caelestia shell                                                    | High*if* 2.2 is half-done                    | Flip`systemd.enable` and remove the exec in the same commit.                                                                                         |
| Logout via`Session.Terminate` hangs SDDM                                | **Happened** (plain session, 2026-09-16) | Shell logout is now`uwsm stop`. Never use `loginctl terminate-session` to leave a session. SysRq S-U-B is the way out if the display hangs anyway. |
| `uwsm stop` from the menu doesn't return to SDDM either | Low; verified working 2026-09-16 | If it ever regresses (e.g. after an SDDM or uwsm bump): CTRL+ALT+F3 → `sudo systemctl restart display-manager`, or SysRq. |
| A newly installed package's XDG autostart entry starts unexpectedly       | Medium over time                               | Check`systemctl --user list-units 'app-*@autostart.service'` after adding GUI packages.                                                              |
| Flake bump breaks a new`--replace-fail`                                 | Medium over time                               | Keep Tier 2 patches minimal; the failure shows up at build time.                                                                                       |
| SilentSDDM doesn't honour`defaultSession`                               | Low                                            | Pick the session manually once; the greeter remembers the last one.                                                                                    |

---

## Checklist

- [X] Tier 1: `withUWSM` + `defaultSession` in the tree
- [X] Tier 1: `nixos-rebuild switch`, log into "Hyprland (uwsm-managed)"; targets, env, autostart checked
- [X] Tier 1: logout via `uwsm stop`, XDG autostart cleanup, `kernel.sysrq = 176`
- [X] Tier 1: logout from the caelestia menu back to SDDM, and log in again
- [X] Tier 1: rest of the verify list (polkit, clipboard, Qt/GTK theme, cursor, screen sharing)
- [X] 2.1: `uwsm/env` + `uwsm/env-hyprland`
- [ ] 2.1: after a verified UWSM login, drop the `QT_QPA_PLATFORMTHEME` dots patch
- [X] 2.3: re-comment `kde-color-sync` / `gtk-theme-sync` (kept on `default.target`)
- [X] 2.2: shell, polkit and cliphist as units; gate `execs.lua`, patch the `keybinds.lua` starts, `KillMode=process`
- [X] 2.2: switch, re-login; units, duplicates and logout verified
- [X] 2.2: polkit prompt, SUPER+V, restart bind (after the kill-bind fix)
- [X] 2.2: nmcli reaper
- [X] 2.2: kill-only bind, launcher apps surviving a restart
- [X] 2.4: `uwsm app` for the launcher, code bind and Dolphin menu; drop-ins for uwsm, self-created and KIO unit names
- [X] 2.4: switch, `daemon-reload`, run the 2.4 verify list
- [ ] 2.4: KIO `.service.d` drop-ins seen matching a Dolphin "Open with" launch
- [X] Update this doc's status line and [`caelestia.md`](caelestia.md)
