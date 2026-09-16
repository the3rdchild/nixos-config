# Hyprland → UWSM

**Status: Tier 1 and 2.1 applied; UWSM login verified 2026-09-16, logout
fix pending a test.** This is the assessment and step list for moving the
Hyprland session from a plain SDDM launch to
[UWSM](https://github.com/Vladimir-csp/uwsm) (Universal Wayland Session
Manager). `withUWSM`, the `hyprland-uwsm` default session and the `uwsm/env*`
files are in the tree, and a login under UWSM came up with the session
targets and environment right. The first login also turned up two things the
plan missed. **Logout through `Session.Terminate` hangs SDDM**, and **UWSM
starts XDG autostart entries**. Both are covered in
[First login findings](#first-login-findings-2026-09-16). 2.2–2.4 are still
open. When a step lands, update this document instead of leaving it
describing the old state.

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

| Plain "Hyprland" session (before, and the fallback) | With UWSM |
|---|---|
| `graphical-session.target` is `inactive`. Anything bound to it never starts, which is why `kde-color-sync` and `gtk-theme-sync` hang off `default.target`. | The target is reached. Home-manager services with a `graphical-session` default work unchanged. |
| Autostart is `hl.exec_cmd` in `execs.lua`. A crash stays dead, and output goes nowhere. | Autostart can be user units with `Restart=`, ordering, and logs in `journalctl --user`. |
| Only the VS Code bind is wrapped in `systemd-run`. Apps from the caelestia launcher run in no scope, so the limits in `home/app-limits.nix` don't reach them. | `uwsm app --` (or `app2unit`) launches into a scope under `app.slice`, which is what the drop-ins match. |
| Logout kills the logind session; nothing is stopped in order. | `uwsm stop` stops the graphical targets in order. (Killing the logind session is *not* a clean alternative here. See the findings below.) |
| XDG autostart (`/etc/xdg/autostart`, `~/.config/autostart`) is never processed. | `xdg-desktop-autostart.target` runs it. This helps, but it also starts anything that was sitting there unnoticed. |

---

## Current state (verified 2026-09-16)

| Piece | Where | Notes |
|---|---|---|
| Hyprland enabled | `modules/package.nix` | `programs.hyprland.enable = true`, `withUWSM = true`. Hyprland 0.56.0 (Lua config), uwsm 0.26.6. D-Bus was already `broker`, which `programs.uwsm` forces, so that part is a no-op. |
| Default session | `modules/sddm.nix` | `services.displayManager.defaultSession = "hyprland-uwsm"`. SilentSDDM greeter. |
| Environment | dots `hypr/hyprland/env.lua` + `uwsm/env`, `uwsm/env-hyprland` (`home/caelestia.nix`) | `hl.env` for Qt/GDK/SDL/Electron backends, `XCURSOR_*`, `XDG_*`. `QT_QPA_PLATFORMTHEME` is patched to `kde` in `home/caelestia.nix`. The uwsm files carry the same values (minus `XDG_*`) for the systemd activation environment; see 2.1. |
| Autostart | dots `hypr/hyprland/execs.lua` | On `hyprland.start`: gnome-keyring (secrets), polkit-gnome agent, 2× `wl-paste --watch cliphist store`, `trash-empty 30`, `hyprctl setcursor` + 2× `gsettings` cursor, geoclue demo agent, `mpris-proxy`, `caelestia shell -d`. gammastep is patched out. |
| Shell service | `home/caelestia.nix` | `programs.caelestia.systemd.enable = false` — otherwise it would run a second shell next to the one `execs.lua` starts. |
| Session-mode daemons | `home/qt.nix`, `home/themes.nix` | `kde-color-sync`, `gtk-theme-sync`: `WantedBy = default.target`, with comments explaining that the graphical target is never reached. |
| Logout | caelestia shell `SessionManager`, `shell.json` | The shell's default `logout` alias is logind `Session.Terminate` over D-Bus, which hangs SDDM (see findings). `home/caelestia.nix` merges `session.commands.logout = ["uwsm", "stop"]` into `shell.json` (activation `caelestiaShellLogout`). No keybind in the dots exits Hyprland. |
| XDG autostart | `/run/current-system/sw/etc/xdg/autostart`, `~/.config/autostart` | Runs under UWSM only. blueman-applet and warp-taskbar start from here. The geoclue demo agent does too, then exits because `execs.lua` already started one. polkit-gnome and onboard entries were removed (see findings). |
| App launch | caelestia shell `launcher/services/Apps.qml` | `DesktopEntry.execute()` — started directly, no systemd scope. |

---

## Tier 1 — switch the session (~30 min) — applied, not verified

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

- [ ] SilentSDDM lists the new session and picks it as the default
- [ ] Caelestia shell up; bar, launcher, notifications
- [ ] Polkit prompt appears (e.g. mount a disk)
- [ ] Clipboard history (SUPER+V) records text and images
- [ ] Qt apps follow dark/light (`kde` platform theme); GTK too
- [ ] Cursor theme/size correct in both Wayland and XWayland apps
- [ ] Screen sharing / portals (Hyprland portal) in the browser
- [ ] **Logout from the caelestia session menu returns to SDDM**, and a
      fresh login from there starts cleanly (no leftover `wayland-wm@*`
      unit). The menu now runs `uwsm stop`, which has not been tested yet.
      Check `jq .session ~/.config/caelestia/shell.json` first, and have
      nothing unsaved open.
- [ ] `systemctl --user --failed` is empty after login

**Rollback:** pick "Hyprland" at the greeter, or revert the two lines. The
menu's logout does nothing in that session, because there is no UWSM session
to stop. No clean way to log out of it has been verified, so leave it with
the menu's reboot or shutdown. Do **not** use `loginctl terminate-session`.

### First login findings (2026-09-16)

**`loginctl terminate-session` / `Session.Terminate` leaves SDDM hung.**
This was hit from the plain Hyprland session, while switching to UWSM:

- logind kills every process in the session scope, including `sddm-helper`.
  SDDM logs `Auth: sddm-helper (… --start …/start-hyprland …) crashed (exit
  code 1)` and then never starts the greeter again. The screen stays on a
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

| Entry | Source | What happened | Action |
|---|---|---|---|
| `onboard` | `home/onboard.nix` (`~/.config/autostart`) | Started the X11 on-screen keyboard, which wvkbd (SUPER+SHIFT+K) replaced | Module removed |
| `polkit-gnome-authentication-agent-1` | `polkit_gnome` in system packages | Lost the race to the `execs.lua` agent ("An authentication agent already exists"), left a failed unit | Package dropped from `modules/hyprland-desktop.nix`; `execs.lua` runs it by store path |
| `blueman` | `services.blueman` | blueman-applet in the tray | Kept |
| `com.cloudflare.WarpTaskbar` | cloudflare-warp | warp-taskbar in the tray | Kept |
| `geoclue-demo-agent` | `services.geoclue2` | "Another instance … is running", exits 0 | Kept; harmless, goes away with 2.2 |
| `xdg-user-dirs` | `xdg-user-dirs` | One-shot update | Kept |

---

## Tier 2 — use it properly (half a day to a day)

### 2.1 Environment variables → UWSM env files — applied, not verified

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

### 2.2 Autostart → systemd user units (optional)

Each `execs.lua` entry, and the unit that could replace it:

| `execs.lua` | Replacement | Notes |
|---|---|---|
| `gnome-keyring-daemon --start --components=secrets` | `services.gnome-keyring` (HM) | WantedBy `graphical-session-pre.target`. Set `components = [ "secrets" ]`. Check it doesn't collide with a PAM-started keyring. |
| polkit-gnome agent | `services.polkit-gnome` (HM) | WantedBy `graphical-session.target`. |
| 2× `wl-paste --watch cliphist store` | `services.cliphist` (HM), `allowImages = true` | Target defaults to `wayland.systemd.target` (graphical-session). |
| `mpris-proxy` | `services.mpris-proxy` (HM) | Bound to the user `bluetooth.target`, not the session — starts when a BT device connects. |
| geoclue demo agent | small custom user unit | Only useful if gammastep comes back. It could simply be dropped. |
| `caelestia shell -d` | `programs.caelestia.systemd.enable = true` | Target defaults to `wayland.systemd.target`. **Must** be removed from `execs.lua` at the same time, or two shells run (see the comment in `home/caelestia.nix`). `keybinds.lua` starts the shell in **three** places, and all of them need patching: CTRL+SUPER+SHIFT+R (`qs -c caelestia kill`, kill only), CTRL+SUPER+ALT+R (kill, then `caelestia shell -d`) and `kbRestoreLock` (`caelestia shell -d`, then lock). `kbRestoreLock` matters most: it is the way back when the shell crashes while locked, and left alone it would start a second shell outside the unit. Check the unit's `Restart=` against the kill-only bind too. |
| `trash-empty 30` | user timer, or leave in `execs.lua` | One-shot; nothing to supervise. |
| `hyprctl setcursor` + `gsettings` cursor | leave in `execs.lua` | Needs the running compositor; cheap and idempotent. |

**Cost:** `execs.lua` is upstream-verbatim apart from the existing patches.
Each line removed is another `--replace-fail` in `home/caelestia.nix`, and
each one is a place a `nix flake update caelestia-dots` can fail the build.
That failure is loud, not silent, but it's still maintenance. Converting the
shell, polkit and cliphist gets most of the benefit; the rest can stay.

### 2.3 Theme daemons → `graphical-session.target`

`kde-color-sync` (`home/qt.nix`) and `gtk-theme-sync` (`home/themes.nix`)
work fine as they are, so this is mostly about keeping the comments true.
Either:

- move them to `graphical-session.target`, with `PartOf` the same target so
  they stop at logout, and rewrite the comments; or
- keep `default.target` and just rewrite the comments. They don't need a
  compositor, so starting early is harmless.

Do this only after dropping the non-UWSM session, or the comments will be
wrong again whenever the fallback session is used.

### 2.4 App launches into scopes (optional)

Caelestia's launcher calls `DesktopEntry.execute()` directly, so launched apps
live in the compositor unit's cgroup and outside the `app-*.scope` drop-ins in
`home/app-limits.nix`. Options:

- Replace the `systemd-run --user --scope …` wrapper on the SUPER+SHIFT+V bind
  (`home/caelestia.nix`) and in `home/mime.nix` with `uwsm app -- code`.
  This is shorter, but **the `app-code-` drop-in stops matching**. uwsm names
  scopes `app-<first XDG_CURRENT_DESKTOP>-<cmd>-<8 hex>.scope` (services use
  `@<hex>` instead) and puts them in `app-graphical.slice` by default. Here
  that gives `app-Hyprland-code-1a2b3c4d.scope`, whose prefix drop-ins are
  `app-Hyprland-code-.scope.d`, `app-Hyprland-.scope.d` and `app-.scope.d`.
  So the drop-in in `home/app-limits.nix` has to be renamed along with the
  wrapper. Otherwise the memory cap silently stops applying. Confirm with
  `systemctl --user show <scope> -p DropInPaths`. The same goes for any app
  that gets launched through `uwsm app` (Zen's `app-flatpak-…` drop-in
  included).
- Patching the launcher in `Apps.qml` to exec `app2unit -- <id>` would cover
  every app, but it's another shell patch against a pinned release tag. Decide
  once 2.1–2.3 are done.

---

## Risks and open questions

| Risk | Likelihood | Mitigation |
|---|---|---|
| Env var only in `env.lua` → wrong theming in systemd/D-Bus-started apps | Medium | 2.1; compare `show-environment` with `env` in a terminal. |
| Double caelestia shell | High *if* 2.2 is half-done | Flip `systemd.enable` and remove the exec in the same commit. |
| Logout via `Session.Terminate` hangs SDDM | **Happened** (plain session, 2026-09-16) | Shell logout is now `uwsm stop`. Never use `loginctl terminate-session` to leave a session. SysRq S-U-B is the way out if the display hangs anyway. |
| `uwsm stop` from the menu doesn't return to SDDM either | Low, untested | Tier 1 checklist. Test with nothing unsaved; recover with CTRL+ALT+F3 → `sudo systemctl restart display-manager`, or SysRq. |
| A newly installed package's XDG autostart entry starts unexpectedly | Medium over time | Check `systemctl --user list-units 'app-*@autostart.service'` after adding GUI packages. |
| Flake bump breaks a new `--replace-fail` | Medium over time | Keep Tier 2 patches minimal; the failure shows up at build time. |
| SilentSDDM doesn't honour `defaultSession` | Low | Pick the session manually once; the greeter remembers the last one. |

---

## Checklist

- [x] Tier 1: `withUWSM` + `defaultSession` in the tree
- [x] Tier 1: `nixos-rebuild switch`, log into "Hyprland (uwsm-managed)"; targets, env, autostart checked
- [x] Tier 1: logout via `uwsm stop`, XDG autostart cleanup, `kernel.sysrq = 176`
- [ ] Tier 1: test logout from the caelestia menu; run the rest of the verify list
- [x] 2.1: `uwsm/env` + `uwsm/env-hyprland`
- [ ] 2.1: after a verified UWSM login, drop the `QT_QPA_PLATFORMTHEME` dots patch
- [ ] 2.3: retarget or re-comment `kde-color-sync` / `gtk-theme-sync`
- [ ] 2.2: shell, polkit and cliphist as units; patch `execs.lua` + restart bind
- [ ] 2.4: `uwsm app --` for the code bind / mime entry; decide on the launcher
- [ ] Update this doc's status line and [`caelestia.md`](caelestia.md)
