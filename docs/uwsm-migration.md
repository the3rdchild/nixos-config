# Hyprland → UWSM

**Status: planned, not applied.** This is the assessment and step list for
moving the Hyprland session from a plain SDDM launch to
[UWSM](https://github.com/Vladimir-csp/uwsm) (Universal Wayland Session
Manager). Nothing in the tree uses UWSM yet; when a step lands, update this
document instead of leaving it describing the old state.

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

| Today | With UWSM |
|---|---|
| `graphical-session.target` is `inactive`. Anything bound to it never starts, which is why `kde-color-sync` and `gtk-theme-sync` hang off `default.target`. | The target is reached. Home-manager services with a `graphical-session` default work unchanged. |
| Autostart is `hl.exec_cmd` in `execs.lua`. A crash stays dead, and output goes nowhere. | Autostart can be user units with `Restart=`, ordering, and logs in `journalctl --user`. |
| Only the VS Code bind is wrapped in `systemd-run`. Apps from the caelestia launcher run in no scope, so the limits in `home/app-limits.nix` don't reach them. | `uwsm app --` (or `app2unit`) launches into a scope under `app.slice`, which is what the drop-ins match. |
| Logout kills the logind session; nothing is stopped in order. | `uwsm stop` / session termination stops the graphical targets cleanly. |

---

## Current state (verified 2026-09-16)

| Piece | Where | Notes |
|---|---|---|
| Hyprland enabled | `modules/package.nix` | `programs.hyprland.enable = true`, no `withUWSM`. Hyprland 0.56.0 (Lua config). |
| Default session | `modules/sddm.nix` | `services.displayManager.defaultSession = "hyprland"`. SilentSDDM greeter. |
| Environment | dots `hypr/hyprland/env.lua` | `hl.env` for Qt/GDK/SDL/Electron backends, `XCURSOR_*`, `XDG_*`. `QT_QPA_PLATFORMTHEME` is patched to `kde` in `home/caelestia.nix`. |
| Autostart | dots `hypr/hyprland/execs.lua` | On `hyprland.start`: gnome-keyring (secrets), polkit-gnome agent, 2× `wl-paste --watch cliphist store`, `trash-empty 30`, `hyprctl setcursor` + 2× `gsettings` cursor, geoclue demo agent, `mpris-proxy`, `caelestia shell -d`. gammastep is patched out. |
| Shell service | `home/caelestia.nix` | `programs.caelestia.systemd.enable = false` — otherwise it would run a second shell next to the one `execs.lua` starts. |
| Session-mode daemons | `home/qt.nix`, `home/themes.nix` | `kde-color-sync`, `gtk-theme-sync`: `WantedBy = default.target`, with comments explaining that the graphical target is never reached. |
| Logout | caelestia shell `SessionManager` | `logout` → logind `Session.Terminate` over D-Bus. It does **not** use `hyprctl dispatch exit`, which UWSM advises against. No keybind in the dots exits Hyprland. |
| App launch | caelestia shell `launcher/services/Apps.qml` | `DesktopEntry.execute()` — started directly, no systemd scope. |

---

## Tier 1 — switch the session (~30 min)

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

`withUWSM` enables `programs.uwsm`, which adds a `hyprland-uwsm` session
("Hyprland (UWSM)", running `uwsm start -F -- /run/current-system/sw/bin/Hyprland`).
The Hyprland module still registers its own session package, so the plain
**Hyprland** entry stays in the greeter as the rollback.

Nothing else has to change for this tier: `execs.lua` still runs, `env.lua`
still applies to everything Hyprland starts, and the two theme daemons still
start from `default.target`.

### Verify

```fish
sudo nixos-rebuild switch --flake /mnt/doc/config#noouoops
# log out, pick "Hyprland (UWSM)" in SilentSDDM, log in

systemctl --user is-active graphical-session.target   # expect: active
systemctl --user status 'wayland-wm@*'                 # the compositor unit
uwsm check is-active && echo ok
systemctl --user show-environment | grep -E 'WAYLAND_DISPLAY|XDG_CURRENT_DESKTOP|QT_QPA'
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
      unit). `Session.Terminate` should bring UWSM down, but this path has
      not been tested yet.

**Rollback:** pick "Hyprland" at the greeter, or revert the two lines.

---

## Tier 2 — use it properly (half a day to a day)

### 2.1 Environment variables → UWSM env files

Under UWSM, `hl.env` only reaches processes Hyprland spawns. Units in the user
manager (portals, D-Bus-activated apps, anything from 2.2) get the systemd
activation environment instead, which UWSM builds from its env files. A
variable that exists only in `env.lua` shows up as Qt/cursor theming that is
right in some apps and wrong in others.

Move them into home-manager:

```nix
xdg.configFile."uwsm/env".text = ''
  export QT_QPA_PLATFORMTHEME=kde
  export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
  export QT_AUTO_SCREEN_SCALE_FACTOR=1
  export GDK_BACKEND=wayland,x11
  export QT_QPA_PLATFORM="wayland;xcb"
  export SDL_VIDEODRIVER=wayland,x11
  export CLUTTER_BACKEND=wayland
  export ELECTRON_OZONE_PLATFORM_HINT=auto
  export _JAVA_AWT_WM_NONREPARENTING=1
'';

xdg.configFile."uwsm/env-hyprland".text = ''
  export XCURSOR_THEME=...   # same value as vars.cursorTheme
  export XCURSOR_SIZE=...
'';
```

- `XDG_CURRENT_DESKTOP` / `XDG_SESSION_TYPE` / `XDG_SESSION_DESKTOP` are set
  by UWSM from the session; don't set them again.
- The cursor values come from caelestia's `variables.lua` and
  `caelestia/hypr-vars.lua` (managed in `home/caelestia.nix`). Take them from
  the same Nix value so the two don't drift apart.
- Leaving `env.lua` as it is causes no harm (same values, set twice). Once the
  UWSM files are confirmed working, the `QT_QPA_PLATFORMTHEME` patch in
  `home/caelestia.nix` can go, which takes one `--replace-fail` off the dots.

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
| `caelestia shell -d` | `programs.caelestia.systemd.enable = true` | Target defaults to `wayland.systemd.target`. **Must** be removed from `execs.lua` at the same time, or two shells run (see the comment in `home/caelestia.nix`). The CTRL+SUPER+SHIFT+R restart bind in `keybinds.lua` should become `systemctl --user restart caelestia`. |
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
  This is shorter, but the scope name changes, so check that the
  `app-code-` drop-in still matches with
  `systemctl --user show <scope> -p DropInPaths`.
- Patching the launcher in `Apps.qml` to exec `app2unit -- <id>` would cover
  every app, but it's another shell patch against a pinned release tag. Decide
  once 2.1–2.3 are done.

---

## Risks and open questions

| Risk | Likelihood | Mitigation |
|---|---|---|
| Env var only in `env.lua` → wrong theming in systemd/D-Bus-started apps | Medium | 2.1; compare `show-environment` with `env` in a terminal. |
| Double caelestia shell | High *if* 2.2 is half-done | Flip `systemd.enable` and remove the exec in the same commit. |
| Logout via `Session.Terminate` doesn't stop UWSM cleanly | Low, untested | Tier 1 checklist; if it fails, set the shell's logout command to `uwsm stop`. |
| Flake bump breaks a new `--replace-fail` | Medium over time | Keep Tier 2 patches minimal; the failure shows up at build time. |
| SilentSDDM doesn't honour `defaultSession` | Low | Pick the session manually once; the greeter remembers the last one. |

---

## Checklist

- [ ] Tier 1: `withUWSM` + `defaultSession`, rebuild, run the verify list
- [ ] 2.1: `uwsm/env` + `uwsm/env-hyprland`; drop the `QT_QPA_PLATFORMTHEME` dots patch
- [ ] 2.3: retarget or re-comment `kde-color-sync` / `gtk-theme-sync`
- [ ] 2.2: shell, polkit and cliphist as units; patch `execs.lua` + restart bind
- [ ] 2.4: `uwsm app --` for the code bind / mime entry; decide on the launcher
- [ ] Update this doc's status line and [`caelestia.md`](caelestia.md)
