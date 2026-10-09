# ── Screenshots and screen recordings.
{ pkgs, lib, qsConfig, ... }: let
  # Both on /mnt/shared rather than under $HOME so the files are reachable
  # from the other OS on this machine. The dots read these from config.json
  # at runtime (Config.options.screenSnip.savePath and .screenRecord.savePath),
  # so what is patched below is the QML default — Settings can still override
  # it, and once it does, config.json wins.
  screenshotDir = "/mnt/shared/Pictures/Screenshots";
  recordingDir = "/mnt/shared/Videos";

  # Print: save a file AND copy. Upstream's bind is `grim ... - | wl-copy`,
  # clipboard only.
  #
  # A script rather than a longer string in keybinds.lua: the bind would
  # otherwise be shell inside a Lua string inside a sed replacement inside a
  # Nix string, and the quoting stops being reviewable. Absolute store paths
  # so it does not depend on what happens to be on PATH in the session.
  printScreenshot = pkgs.writeShellScript "ii-print-screenshot" ''
    export PATH=${lib.makeBinPath [ pkgs.grim pkgs.jq pkgs.wl-clipboard pkgs.libnotify pkgs.coreutils pkgs.hyprland ]}
    dir="${screenshotDir}"
    mkdir -p "$dir"
    f="$dir/screenshot-$(date '+%Y-%m-%d_%H.%M.%S').png"
    grim -o "$(hyprctl activeworkspace -j | jq -r '.monitor')" - | tee "$f" | wl-copy
    notify-send "Screenshot saved" "$f" -a Screenshot -i image-x-generic
  '';
in {
  patch = ''
    # ── Capture destinations.
    #
    # end4-pC is the shell that runs by default; ii gets the same treatment
    # where it has the same knob, without failing the build if it does not.
    substituteInPlace $out/.config/quickshell/${qsConfig}/modules/common/Config.qml \
      --replace-fail \
        'property string savePath: "" // only copy to clipboard when empty' \
        'property string savePath: "${screenshotDir}"' \
      --replace-fail \
        'property string savePath: Directories.videos.replace("file://","") // strip "file://"' \
        'property string savePath: "${recordingDir}"'

    for f in $out/.config/quickshell/ii/modules/common/Config.qml; do
      [ -e "$f" ] || continue
      sed -i \
        -e 's|property string savePath: "" // only copy to clipboard when empty|property string savePath: "${screenshotDir}"|' \
        -e 's|property string savePath: Directories.videos.replace("file://","") // strip "file://"|property string savePath: "${recordingDir}"|' \
        "$f"
    done

    # ── Recording keys: SUPER+ALT+R is fullscreen with sound,
    # SUPER+SHIFT+ALT+R the region selector.
    #
    # Upstream has the two the other way round; these are the ones in muscle
    # memory. Everything else in the capture group is upstream's, and the
    # region selector is deliberately left alone — it opens a toolbar (copy /
    # edit via swappy / search / OCR / record / record with sound) worth
    # keeping as it is.
    #
    # Each anchor carries its action, so the two rewrites cannot collide: after
    # the first two lines become SUPER+SHIFT+ALT+R they no longer match the
    # third pattern, which names a different command.
    substituteInPlace $out/.config/hypr/hyprland/keybinds.lua \
      --replace-fail \
        'hl.bind("SUPER + ALT + R", hl.dsp.global("quickshell:regionRecord"), { locked = true })' \
        'hl.bind("SUPER + SHIFT + ALT + R", hl.dsp.global("quickshell:regionRecord"), { locked = true })' \
      --replace-fail \
        'hl.bind("SUPER + ALT + R", hl.dsp.exec_cmd(qsIsAlive .. " || " .. qsScripts .. "/videos/record.sh"), { locked = true })' \
        'hl.bind("SUPER + SHIFT + ALT + R", hl.dsp.exec_cmd(qsIsAlive .. " || " .. qsScripts .. "/videos/record.sh"), { locked = true })' \
      --replace-fail \
        'hl.bind("SUPER + SHIFT + ALT + R", hl.dsp.exec_cmd(qsScripts .. "/videos/record.sh --fullscreen --sound"),' \
        'hl.bind("SUPER + ALT + R", hl.dsp.exec_cmd(qsScripts .. "/videos/record.sh --fullscreen --sound"),'

    # Print saves a file as well as copying, and CTRL+Print follows it to the
    # same directory instead of ~/Pictures/Screenshots.
    substituteInPlace $out/.config/hypr/hyprland/keybinds.lua \
      --replace-fail \
        'hl.bind("Print", hl.dsp.exec_cmd(grimhyprctl .. " - | wl-copy"),' \
        'hl.bind("Print", hl.dsp.exec_cmd("${printScreenshot}"),' \
      --replace-fail \
        'mkdir -p $(xdg-user-dir PICTURES)/Screenshots && ' \
        'mkdir -p ${screenshotDir} && '
  '';
}
