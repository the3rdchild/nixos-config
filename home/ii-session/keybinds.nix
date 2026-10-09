# ── Keybinds changed or added on top of upstream's keybinds.lua.
#
# Hyprland fires every bind that matches, so a changed key is always a
# replacement of upstream's line, never an extra bind beside it.
{ pkgs, lib, fill, ... }: rec {
  # SUPER+SHIFT+B → pwvucontrol, as a show/hide toggle.
  #
  # pwvucontrol is GTK4 without single-instance handling, so a plain
  # `exec_cmd pwvucontrol` bind stacks a fresh window on every press. This
  # does the three-state toggle instead: launch if absent, focus if open but
  # unfocused, close if it is the active window.
  #
  # The class is matched case-insensitively on the substring rather than
  # pinned to the literal `com.saivert.pwvucontrol` app-id, so the bind keeps
  # working if upstream renames it.
  volumeControlToggle = pkgs.writeShellScriptBin "volume-control-toggle" ''
    jq=${pkgs.jq}/bin/jq
    addr=$(hyprctl clients -j | $jq -r 'first(.[] | select(.class | test("pwvucontrol"; "i")) | .address) // empty')

    if [ -z "$addr" ]; then
      exec ${pkgs.pwvucontrol}/bin/pwvucontrol
    elif [ "$addr" = "$(hyprctl activewindow -j | $jq -r '.address // empty')" ]; then
      hyprctl dispatch closewindow "address:$addr"
    else
      hyprctl dispatch focuswindow "address:$addr"
    fi
  '';

  # SUPER+SHIFT+Q (hold): close every window, one at a time.
  #
  # Current workspace first, then 1, 2, 3, … and the special workspaces last,
  # switching to each so both the workspace slide and each window's popin-out
  # animation are visible. Releasing Q (with SUPER+SHIFT still down) or SUPER
  # stops it where it is; letting go of SHIFT alone does not.
  #
  # Press and release are two separate exec_cmds, so nothing orders them: on a
  # quick tap the release can land before this script has even started. The
  # keybind therefore hands both halves the same per-press token, and "stop"
  # just drops a file named after it — whichever side runs first, the start
  # side sees it. The 300ms grace before the first close is what makes a tap a
  # no-op rather than "closes one window".
  #
  # Each window gets the same polite close as SUPER+Q; one that is still there
  # 1.5s later (an unsaved-changes prompt, a hung app) is force-killed —
  # Hyprland's kill dispatcher first, then SIGKILL on its pid as a backstop.
  closeSequential = pkgs.writeShellScript "ii-close-sequential" (fill ./files/close-sequential.sh {
    path = lib.makeBinPath [ pkgs.hyprland pkgs.jq pkgs.libnotify pkgs.coreutils pkgs.findutils pkgs.util-linux ];
  });

  patch = ''
    # ── SUPER+I opens Settings in whichever shell is running.
    #
    # end4-pC's Settings is an overlay panel reached over IPC
    # (modules/ii/settings/Settings.qml:170); its README asks for SUPER+Escape.
    # SUPER+I is used instead because ii already binds it to "App: Settings
    # app" (keybinds.lua:354) and that binding is dead under end4-pC — its
    # first candidate is `qs -p .../$qsConfig/settings.qml`, a file end4-pC
    # doesn't have, so it falls through to systemsettings.
    #
    # Both lines are needed and both have to be inert in the other shell: the
    # global is a no-op under ii (no such IPC handler there), and the exec is
    # guarded on the settings.qml that only ii ships. Exactly one thing
    # happens either way.
    #
    # SUPER+ALT+S was the first idea and is not free — keybinds.lua:241 uses it
    # for "Window: Send to scratchpad".
    sed -i 's|^hl.bind("SUPER + I", hl.dsp.exec_cmd(settingsApp), { description = "App: Settings app" })$|hl.bind("SUPER + I", hl.dsp.global("quickshell:settingsToggle"), { description = "App: Settings" })\nhl.bind("SUPER + I", hl.dsp.exec_cmd("[ -f $HOME/.config/quickshell/$qsConfig/settings.qml ] \&\& " .. settingsApp))|' \
      $out/.config/hypr/hyprland/keybinds.lua
    grep -q 'quickshell:settingsToggle' $out/.config/hypr/hyprland/keybinds.lua

    # ── SUPER+W is unbound.
    #
    # Upstream opens the browser on it; asked to have it removed outright
    # rather than moved. Checked before and after so an upstream rewording
    # fails the build instead of leaving the bind silently in place.
    grep -q '^hl.bind("SUPER + W", hl.dsp.exec_cmd(browser),' $out/.config/hypr/hyprland/keybinds.lua
    sed -i '/^hl.bind("SUPER + W", hl.dsp.exec_cmd(browser),/d' \
      $out/.config/hypr/hyprland/keybinds.lua
    [ "$(grep -c '"SUPER + W"' $out/.config/hypr/hyprland/keybinds.lua)" = "0" ] || exit 1

    # ── SUPER+SHIFT+B: the volume window (see volumeControlToggle).
    #
    # Not SUPER+B, which is upstream's second key for the left sidebar.
    # SUPER+SHIFT+B was upstream's "Media: Previous track"
    # (keybinds.lua:135-136), and that is the one thing this costs:
    # previous-track keeps XF86AudioPrev (:132, the media key on the external
    # keyboard, which presents a Consumer Control device) and
    # SUPER+SHIFT+ALT+mouse:275 (:133). Next/play-pause are untouched.
    #
    # sed with N rather than --replace-fail, because this bind spans two lines
    # and a multi-line anchor would need its continuation line's indentation
    # spelled exactly. N pulls the options line into the pattern space and
    # both become one line. Counted before and after: the anchor is unique,
    # and so is the description it carries.
    before=$(grep -c 'hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd("playerctl previous"),' \
      $out/.config/hypr/hyprland/keybinds.lua)
    [ "$before" = "1" ] || { echo "SUPER+SHIFT+B: expected 1 anchor, found $before" >&2; exit 1; }
    sed -i '/^hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd("playerctl previous"),$/{N;s|.*|hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd("volume-control-toggle"), { description = "App: Volume control" })|}' \
      $out/.config/hypr/hyprland/keybinds.lua
    grep -q 'hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd("volume-control-toggle")' \
      $out/.config/hypr/hyprland/keybinds.lua
    [ "$(grep -c 'Media: Previous track' $out/.config/hypr/hyprland/keybinds.lua)" = "0" ] || exit 1
    # The left sidebar keeps all three of upstream's keys (SUPER+A, +B, +O);
    # nothing here touches them.
    [ "$(grep -c 'quickshell:sidebarLeftToggle"' $out/.config/hypr/hyprland/keybinds.lua)" = "3" ] || exit 1

    # ── New binds: apps on SUPER+SHIFT+Z/V/O, and SUPER+SHIFT+Q held.
    #
    # Appended rather than substituted: these replace nothing, and
    # keybinds.lua is a flat list of top-level statements, so the end of the
    # file is as good a place as any and reads as ours rather than upstream's.
    #
    # `code`, not `uwsm app -- code`: this session is deliberately not uwsm
    # (../../modules/ii-session.nix says why), so there is no uwsm session for
    # `uwsm app` to attach to. The cost is real and worth naming:
    # ../app-limits.nix caps VS Code through the app-Hyprland-code-<hex>.scope
    # that `uwsm app` creates, so VS Code runs uncapped here. Zen is
    # unaffected — flatpak makes its own transient scope, which is what that
    # file's drop-in actually targets.
    cat >> $out/.config/hypr/hyprland/keybinds.lua <<'IIBINDS'

    --# Apps, aligned with the caelestia session
    hl.bind("SUPER + SHIFT + Z", hl.dsp.exec_cmd("flatpak run app.zen_browser.zen"), { description = "App: Zen browser" })
    hl.bind("SUPER + SHIFT + V", hl.dsp.exec_cmd("code"), { description = "App: VS Code" })
    hl.bind("SUPER + SHIFT + O", hl.dsp.exec_cmd("obsidian"), { description = "App: Obsidian" })

    --# Close every window one by one while held; letting go of any key stops it
    local closeSeqToken = nil
    local function closeSeqStop()
        if closeSeqToken then
            hl.dispatch(hl.dsp.exec_cmd("${closeSequential} stop " .. closeSeqToken))
            closeSeqToken = nil
        end
    end
    hl.bind("SUPER + SHIFT + Q", function()
        closeSeqStop()
        closeSeqToken = os.time() .. "-" .. math.random(1, 1000000000)
        hl.dispatch(hl.dsp.exec_cmd("${closeSequential} start " .. closeSeqToken))
    end, { description = "Window: Close all, one by one (hold)" })
    hl.bind("SUPER + SHIFT + Q", closeSeqStop, { release = true })
    --# Not bare Q or SHIFT_*: a release bind on a plain key swallows its press
    --# even with transparent, so q stopped typing. SUPER_* already carry the same
    --# kind of bind upstream (workspaceNumber, top of this file) without harm.
    for _, key in ipairs({ "SUPER_L", "SUPER_R" }) do
        hl.bind(key, closeSeqStop, { release = true, ignore_mods = true, transparent = true })
    end
    IIBINDS
  '';
}
