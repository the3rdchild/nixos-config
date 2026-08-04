# Caelestia desktop

The Hyprland desktop on this machine is [caelestia](https://github.com/caelestia-dots),
wired into NixOS declaratively. This replaced JaKooLit's Hyprland-Dots in
`3.0-beta`.

---

## Upstream, in two halves

Caelestia is two separate repos, and the distinction matters because they are
packaged completely differently.

| | repo | what it is | flake? |
|---|---|---|---|
| **shell** | `caelestia-dots/shell` | quickshell app — bar, launcher, notifications, lock screen, OSDs | yes, exports a home-manager module |
| **dots** | `caelestia-dots/caelestia` | plain config files — hypr, foot, btop, fish, … | no |

The shell is a *single process* that owns everything a JaKooLit setup spreads
across waybar + rofi + swaync + wlogout + hyprlock. There is no bar config to
edit; it is QML inside the package.

Both come in as flake inputs (`flake.nix`). The shell's flake pins its own
**quickshell from git** — nixpkgs' tagged quickshell is too old to build it, so
never substitute `pkgs.quickshell` here.

---

## Where things live

| file | owns |
|---|---|
| [`home/caelestia.nix`](../home/caelestia.nix) | everything caelestia — the patched dots, the shell, config placement, packages |
| [`modules/hyprland-desktop.nix`](../modules/hyprland-desktop.nix) | system-level support: polkit, geoclue, dconf, ydotool, portals |
| [`modules/package.nix`](../modules/package.nix) | `programs.hyprland`, the Hyprland package itself |
| [`home/shell.nix`](../home/shell.nix) | fish — caelestia's `config.fish` ported into home-manager options |
| [`home/themes.nix`](../home/themes.nix) | GTK / icon / cursor themes (independent of the caelestia palette) |

---

## How the Nix integration works

Four decisions carry the whole design. They are the reason this is declarative
where the previous setup could not be.

### 1. The dots are patched, not copied

Upstream is Arch-first and hardcodes FHS paths that silently no-op on NixOS.
`home/caelestia.nix` derives a patched tree with `runCommand` and rewrites three
things:

| upstream | patched to | breaks if unpatched |
|---|---|---|
| `/usr/lib/polkit-gnome/…agent-1` | `${polkit_gnome}/libexec/…` | every polkit prompt (mounting, nmtui) |
| `/usr/lib/geoclue-2.0/demos/agent` | `${geoclue2-with-demo-agent}/libexec/…` | gammastep auto-location |
| `QT_QPA_PLATFORMTHEME=qtengine` | `qt6ct` | Qt app theming (qtengine is AUR-only) |

Because it is a derivation over a flake input, `nix flake update caelestia-dots`
is a safe bump — the patches re-apply or the build fails loudly.
`--replace-fail` guarantees the latter: if upstream renames a path, the build
errors rather than silently producing a broken config.

### 2. `~/.config/hypr` uses recursive symlinks

```nix
xdg.configFile."hypr" = { source = "${dots}/hypr"; recursive = true; };
```

`recursive = true` is **load-bearing**. Without it home-manager symlinks the
whole directory read-only. With it, real directories are created and only the
*files* are symlinked — which leaves room for `hyprland.lua` to write
`scheme/current.lua` next to the symlinked `scheme/default.lua` at runtime.

This is precisely what JaKooLit's dots could not do: they rewrote their own
configs in place, so a store symlink broke them, so the whole tree had to stay
unmanaged.

### 3. Configs the app rewrites are copied, not linked

`btop.conf` and `micro/settings.json` are written by their own apps on exit. A
store symlink is read-only, so these are copied once via a
`home.activation` hook and then left alone. Declarative ownership is
deliberately given up here — the alternative is an app that cannot save state.

Everything else (`foot.ini`, `fastfetch/config.jsonc`, the hypr Lua) is only
ever read, so it stays a symlink.

### 4. The shell starts from Hyprland, not systemd

`programs.caelestia.systemd.enable = false`. The hypr config already launches it
(`caelestia shell -d` in `execs.lua`) and the restart keybind kills and respawns
it the same way. Running the systemd unit *as well* gives two shells fighting
over the same layer surfaces.

Consequence: **the shell only appears on a fresh session.** A rebuild alone
will not start it.

---

## Theming

Three independent layers. Know which one you want.

### The caelestia scheme — everything the shell draws

```fish
caelestia scheme set -n catppuccin -f mocha -m dark
caelestia scheme set -r          # random
caelestia scheme get             # what's active
caelestia scheme list -n         # just the names
```

| scheme | flavours |
|---|---|
| `catppuccin` | latte, macchiato, frappe, mocha |
| `gruvbox`, `everforest` | soft, hard, medium |
| `rosepine` | moon, dawn, main |
| `nord`, `dracula`, `tokyonight`, `solarized`, `everblush` | medium |
| `caelestia`, `onedark`, `oldworld`, `shadotheme` | default |
| `dynamic` | default, hard |

Also `-m dark|light` and `-v tonalspot|vibrant|expressive|fidelity|…`.

### Wallpaper-derived (Material You)

```fish
caelestia scheme set -n dynamic
caelestia wallpaper -f ~/Pictures/foo.png
caelestia wallpaper -r                       # random from a dir
```

**How terminals pick this up:** there are no colours in `foot.ini`. The scheme
is written to `~/.local/state/caelestia/sequences.txt` as escape sequences, and
`home/shell.nix` replays it on every interactive fish start. A terminal opened
before a scheme change keeps the old palette until the next shell.

### GTK apps, icons, cursor

Separate, and owned by [`home/themes.nix`](../home/themes.nix):

```fish
theme-switch                 # list the 7 registered themes
theme-switch tokyo-night
```

The **cursor** is the one value both sides share. `themes.activeCursor` is
exported and baked into `hypr-vars.lua`, so changing the theme here also
changes the Hyprland cursor — after a rebuild and re-login.

---

## Keybinds

No cheatsheet panel exists in the shell. Live and authoritative:

```fish
hyprctl binds
hyprctl binds | grep -A3 -i super
```

Source of truth is `~/.config/hypr/hyprland/keybinds.lua`; key names resolve
through `variables.lua`, overridden by `~/.config/caelestia/hypr-vars.lua`
(generated — edit `home/caelestia.nix`, not the file).

| | |
|---|---|
| `SUPER` tap | launcher |
| `SUPER+T` `+C` `+E` | foot, code, dolphin |
| `SUPER+Q` `+F` `+P` | close, fullscreen, pin |
| `SUPER+ALT+Space` | toggle floating |
| `SUPER+Z` / `SUPER+X` | move / resize with mouse |
| `SUPER+1..0` | workspace (`+ALT` moves window there) |
| `CTRL+SUPER+←/→` | prev / next workspace |
| `SUPER+S` `+M` `+D` `+R` | special, music, comms, todo scratchpads |
| `CTRL+SHIFT+Esc` | system monitor |
| `SUPER+N` `+K` | sidebar, show all panels |
| `SUPER+L` / `SUPER+SHIFT+L` | lock / suspend |
| `Print` / `SUPER+SHIFT+S` | screenshot (full / freeze-region) |
| `SUPER+V` / `SUPER+.` | clipboard / emoji |
| `SUPER+SHIFT+C` | colour picker |
| `CTRL+ALT+Del` | session menu |
| `CTRL+SUPER+ALT+R` | restart shell |
| `CTRL+SUPER+SHIFT+R` | kill shell |

### Changing a keybind

Keys come from `variables.lua`. Override them in the `hypr-vars.lua` block of
`home/caelestia.nix` — e.g. `kbTerminal = "SUPER + Return"`. For binds not
driven by a variable, the honest options are to patch `keybinds.lua` in the
`runCommand`, or append your own file. Do not edit `~/.config/hypr/**`; it is a
store symlink and changes will be lost.

---

## Rebuilding

> **`/etc/nixos` is a manual copy of this repo, not a symlink.**
> The `nrs` alias builds from `/etc/nixos`, so edits here have no effect until
> copied across. Diff rather than blind-copy — the two have drifted before.

```fish
sudo nixos-rebuild switch --flake /mnt/doc/config#noouoops   # from the repo
nrs                                                          # from /etc/nixos
```

Rollback: pick the previous generation at boot, or
`sudo nixos-rebuild switch --rollback`.

### Updating caelestia

```fish
nix flake update caelestia-shell caelestia-dots
```

The shell compiles from source (quickshell + C++/QML), so expect a few minutes.
If the dots update renames a patched path, the build fails at
`substituteInPlace` — fix the substitution in `home/caelestia.nix`.

---

## Troubleshooting

**No bar after login.** Run `caelestia shell` in a foreground terminal and read
the error. Do not guess.

**Shell alive but wrong/stale.** `CTRL+SUPER+ALT+R`, or
`qs -c caelestia kill; caelestia shell -d`.

**`qs: command not found`.** `qs` must be the *same build* the shell runs.
`home/caelestia.nix` pins it by mirroring `shell/nix/default.nix` exactly,
including the `withModules` call. Verify:

```fish
readlink -f (which qs)
nix-store -q --references (nix eval --raw /mnt/doc/config#nixosConfigurations.noouoops.config.home-manager.users.noouoops.programs.caelestia.package) | grep quickshell
```

Both must name the same `quickshell-wrapped` store path.

**Rebuild fails: `Existing file 'X.backup' would be clobbered`.** A stale
`.backup` from an earlier run is in the way. Home-manager refuses to overwrite
it rather than destroy data. Move the `.backup` aside and re-run. This is
unrelated to caelestia and can block any rebuild.

Note `~/.config/Code/**/state.vscdb.backup` files are **VS Code's own** SQLite
backups, not home-manager artifacts — leave them alone.

**Re-running just home-manager** (when the system generation already switched):

```fish
sudo systemctl restart home-manager-noouoops.service
```

To preview without applying, pass the env the unit sets — omitting it makes the
collision check hard-error instead of backing up, which looks like a failure
that isn't one:

```fish
set gen (systemctl cat home-manager-noouoops.service | grep -oE '/nix/store/[a-z0-9]+-home-manager-generation')
env DRY_RUN=1 HOME_MANAGER_BACKUP_EXT=backup $gen/activate
```

**ydotool bind does nothing.** `/dev/uinput` access comes from the `ydotool`
group in `modules/user.nix`. Group changes need a full logout, not just a
rebuild.

---

## Migration notes (3.0-beta)

Removed with the JaKooLit setup: `home/hyprland-dots.nix`, `home/waybar.nix`,
`home/rofi-themes.nix`, `home/hyprland/`, `scripts/patch-dots-nixos.sh`, and the
`hyprmod` flake input. Net −680/+380 lines.

Two workarounds died with it, both worth remembering as symptoms of fighting the
package manager:

- an `awww`→`swww` symlink shim, needed because the dots' `pgrep -x swww-daemon`
  checks never matched through nixpkgs' wrapper scripts;
- `patch-dots-nixos.sh`, which re-`sed`ed upstream files after every update
  because the dots' own updater restored them.

The pre-migration `~/.config` (hypr, waybar, rofi, swaync, wlogout, wallust,
ags) was moved to `~/.config-pre-caelestia-<timestamp>/`, not deleted. Safe to
remove once you're settled.

**Kept deliberately:** `kitty` alongside `foot` (foot is the `SUPER+T` default
because the scheme recolours it), and `themes.nix`, which still owns GTK.
