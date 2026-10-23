# ── Video wallpapers.
#
# switchwall.sh plays a video wallpaper with mpvpaper on Hyprland's
# background layer, and the shell's own wallpaper window — the bottom layer,
# just above it — goes transparent to let it through. Everything that needs
# a *picture* of the video (the palette, the light/dark measure, the tile in
# the selector, the preview while arrowing through it) uses one still frame
# instead. Upstream extracted that frame in one place, switchwall.sh, and
# only once the video was already being applied, so everything that runs
# before that point had nothing to look at: scheme detection fed the .mp4
# itself to a Python image loader, the selector never listed videos at all
# (Wallpapers.qml's extension list still says "TODO: add videos"), and the
# preview showed the thumbnail of whatever wallpaper was already set.
#
# end4-pC only: it is the shell that runs, and ii's copies of these files
# have drifted from it (its switchwall.sh has no colors-only mode), so one
# set of anchors cannot cover both.
{ pkgs, lib, fill, ... }: rec {
  # One helper, so the frame has one name and one recipe wherever it is asked
  # for. The name is upstream's — <basename>.jpg under hypr/custom/scripts/
  # mpvpaper_thumbnails, writable because hypr/custom is in mutablePaths —
  # which keeps background.thumbnailPath meaning what the rest of the shell
  # already reads it as. First frame, as upstream; redone when the video is
  # newer than it. Written under a temp name and moved into place, because the
  # thumbnail pass and switchwall.sh can ask for the same frame at once and the
  # shell may be reading it. -q:v 2 because this frame is shown full screen,
  # during the preview and the transition into the video, and ffmpeg's default
  # JPEG quality is visibly blocky at 1080p.
  videoFrame = pkgs.writeShellScript "ii-video-frame" (fill ./files/video-frame.sh {
    path = lib.makeBinPath [ pkgs.ffmpeg pkgs.coreutils ];
  });

  # What mpvpaper actually plays: the video itself, or a 1080p30 copy of it.
  #
  # Measured on this machine with a 4K60 H.264 wallpaper (40 Mbit/s), one
  # monitor: the iGPU's video-decode engine 79% busy, and 211 of ~300 frames
  # dropped in 5s — every monitor runs its own mpvpaper, so two of those are
  # past what the engine can do. Capping at playback does not help: mpv's
  # fps filter still has to decode every frame, since each is coded against
  # the others (79% again, 86 of 150 dropped). A 1080p30 copy decodes at 13%
  # with nothing dropped, so the copy is made once and played from then on.
  #
  # Only ever smaller: scaled down until it just covers a 1920x1080 screen
  # (mpvpaper crops to fill, so a wider video keeps its full height), and
  # dropped to 30fps only if it is faster. Anything already within both is
  # played as it is. Made on the iGPU (35s for a 21s 4K60 clip — the 4K
  # decode is the slow half, the low-power encoder was no faster) and
  # indistinguishable from a proper downscale at 1080p; libx264 is the
  # fallback for anything VA-API will not decode. The copy lives in the cache,
  # keyed on the source's path, size and mtime, so replacing a video makes a
  # new one and clearing the cache only costs one more conversion.
  #
  # A bin, not a store path, because the restore script switchwall.sh writes
  # into hypr/custom calls it at every login and outlives any store path.
  #
  # --cached never converts: it prints what to play only if that needs no
  # conversion or the copy is already made, and fails otherwise. The lock
  # screen asks that way (see mpvpaperCtl), so locking never waits on a
  # conversion. The lock video's copy is started as soon as it is picked
  # (see the switchwall.sh patch), which is the second way two conversions of
  # one video can overlap — the flock makes the later one wait for the first
  # and then use its copy.
  videoProxy = pkgs.writeShellScriptBin "ii-video-proxy" (fill ./files/video-proxy.sh {
    path = lib.makeBinPath [ pkgs.ffmpeg pkgs.coreutils pkgs.gawk pkgs.libnotify pkgs.util-linux ];
  });

  # Pause or resume one monitor's video, over the mpv IPC socket switchwall.sh
  # opens per output. The asked-for behaviour is that the
  # video stops only while something covers it: a fullscreen window, or the
  # overview (see videoQml.background for why that one matters). mpvpaper's
  # own --auto-pause cannot do that here: it pauses when the compositor stops
  # sending frame callbacks, and Hyprland does not stop — tested on this
  # machine, an mpvpaper covered edge to edge by the shell's opaque wallpaper
  # kept decoding for as long as it ran. The shell already tracks fullscreen
  # per monitor (for hideWhenFullscreen), so it sends the pause itself. Paused,
  # the same test used 1 tick of CPU per 2s against 25 playing.
  #
  # Waits for the socket, because the shell can ask the moment a wallpaper
  # goes live, and that is also the moment mpvpaper was spawned; the socket
  # took ~300ms to appear in testing. A stale one (mpvpaper is killed with -9,
  # which leaves the file behind) just refuses the connection.
  #
  # Given a video as well, it also makes that the one playing, which is how
  # the lock screen plays its own wallpaper live (see videoQml.background):
  # the same mpvpaper loads the lock video on lock and the desktop's again on
  # unlock, so there is never a second decoder, and the hidden desktop video
  # is not decoding meanwhile. loadfile starts the desktop video from the
  # beginning, as asked. With `lock`, a desktop that has no mpvpaper (a still
  # wallpaper) gets one started for the lock video, which `stop` kills on
  # unlock; and a lock video whose 1080p30 copy is not made yet is not played
  # at all (exit 3, so the lock screen keeps its frame) — the copy is started
  # instead, for the next lock. The desktop's own video is never held back
  # that way: it plays the original if it has to, as switchwall.sh does.
  #
  # Exits once mpv reports the file loaded, so the shell's reveal starts from
  # a video that is actually there. The shell serialises its calls per
  # monitor, so two never race on one mpvpaper.
  mpvpaperCtl = pkgs.writeShellScript "ii-mpvpaper-ctl" (fill ./files/mpvpaper-ctl.sh {
    path = lib.makeBinPath [ pkgs.socat pkgs.coreutils pkgs.jq pkgs.procps pkgs.util-linux pkgs.mpvpaper videoProxy ];
    inherit videoOpts;
  });

  # mpvpaper's options, exactly as switchwall.sh sets them once the patch has
  # added profile=fast (checked there), for the mpvpaper the lock screen
  # starts itself.
  videoOpts = "no-audio loop hwdec=auto scale=bilinear interpolation=no video-sync=display-resample panscan=1.0 video-scale-x=1.0 video-scale-y=1.0 video-align-x=0.5 video-align-y=0.5 load-scripts=no profile=fast";

  # The QML the patch inserts, unindented; insert_after re-indents each to
  # its insertion point.
  videoQml = {
    # Images.qml, next to its image list.
    images = pkgs.writeText "ii-video-images.qml" (builtins.readFile ./files/video-images.qml);

    # Wallpapers.qml. confirmedPath is set by apply() and never cleared, so
    # after one pick from the selector the background ignored every later
    # change that did not come through apply() — a wallpaper chosen in the
    # file dialog, or set by switchwall.sh directly, never appeared. It only
    # has to bridge the moment before switchwall.sh writes the config; once
    # the config moves, the config is the truth again.
    #
    # requestThumbnails is for the video tiles below: thumbnails are only ever
    # generated from the selector's "Update thumbnails" button, and nothing
    # else makes one for a video. One pass covers the whole folder, and the
    # tiles already reload on thumbnailGenerated, so the first tile to ask is
    # enough and the rest are dropped while it runs.
    wallpapers = pkgs.writeText "ii-video-wallpapers.qml" (builtins.readFile ./files/video-wallpapers.qml);

    # Inside the selector tile's ThumbnailImage: ask for a thumbnail once if a
    # video has none, and mark video tiles with a play badge. The badge is a
    # child of the image, so it fades in with it and sits inside its rounded
    # mask.
    tile = pkgs.writeText "ii-video-tile.qml" (builtins.readFile ./files/video-tile.qml);

    # Background.qml, per monitor. Only the applied wallpaper is ever playing
    # — mpvpaper is started by switchwall.sh, never by a preview — so only
    # then is there anything behind this window worth revealing. Upstream
    # revealed for any video path, which during a preview meant going
    # transparent over a video that was not running. A previewed video, or one
    # picked but not yet written to the config, now shows its frame like an
    # image.
    #
    # The reveal waits 500ms after the video goes live: switchwall.sh starts
    # mpvpaper just before it writes the config, and mpvpaper needs a moment
    # to put up its first frame; revealing at once shows the empty layer
    # beneath for that moment.
    #
    # A video that has never been through the thumbnail pass has no frame
    # until switchwall.sh extracts it, and it writes thumbnailPath straight
    # after, so a failed load is retried then.
    #
    # "Live" means the path ii-mpvpaper-ctl reports playing (playingPath), not
    # just the applied wallpaper, because the lock screen switches mpvpaper to
    # its own video (see mpvpaperCtl): locked, the lock video is revealed once
    # it has loaded, through the same 500ms delay; unlocked, the desktop's
    # again once it has loaded back. Until then — or for good, if the lock
    # video's 1080p30 copy is not made yet — the frame is shown, as for a
    # preview. With the lock blur on, the lock screen shows the blurred frame
    # as before and nothing is switched.
    #
    # Unlocked, the video pauses while a fullscreen window covers it. Locked,
    # it plays only if it is what the lock screen shows (so a still lock
    # wallpaper, or the blur, pauses the desktop video behind it), and pauses
    # while its screen is off.
    #
    # The pause also covers the niri-style overview, whose own blur
    # (overviewBlurActive, upstream's condition, reused as is) paints this
    # window full screen with a blurred copy of the still frame — the video is
    # already hidden then. Pausing it is what keeps the overview smooth:
    # rules.lua blurs every quickshell:* layer, and Hyprland caches the blur
    # of what lies beneath only until that changes. A video beneath changes it
    # every frame, so the full-screen blur was being redone at the video's
    # frame rate while the overview scrolled at the monitor's.
    background = pkgs.writeText "ii-video-background.qml" (fill ./files/video-background.qml {
      inherit mpvpaperCtl;
    });
  };

  # switchwall.sh's video branch, before and after. Upstream wrote the config
  # first, then started mpvpaper, then extracted the frame and wrote
  # thumbnailPath — so the shell saw the new wallpaper before the video was
  # running or its frame existed. Now the frame comes first, then mpvpaper,
  # then thumbnailPath and wallpaperPath, in the order the shell reads them.
  # Each mpvpaper plays what videoProxy hands back (the socket mpvpaperCtl
  # talks to is upstream's); the config keeps the original's path, which is
  # what the selector, the frame and the restore script go by.
  #
  # Replaced as one block rather than line by line because the reorder moves
  # lines across each other; the old text is spelled out so any upstream change
  # to it fails the build instead of applying half a patch.
  videoSwitch = {
    old = pkgs.writeText "ii-video-switch-old" (builtins.readFile ./files/switchwall-video-old.sh);
    new = pkgs.writeText "ii-video-switch-new" (fill ./files/switchwall-video-new.sh {
      inherit videoFrame videoProxy;
      blurCacheOff = blurCache false;
    });
  };

  # ── Blur over a live wallpaper.
  #
  # Measured on this machine with a 30fps 1080p video: mpv dropped ~16 of
  # every 30 frames, the same in every sync mode, and with framedrop=no the
  # video ran at half speed instead. Not one frame could be drawn when mpv
  # had it ready; every one waited on Hyprland's frame callback, which came
  # ~14 times a second on a 120Hz output. The compositor itself was the
  # bottleneck, which is also why the whole desktop felt slow and why the same
  # video in a browser did not: a browser window does not sit *under* the blur.
  # With blur off, 0 drops. The two things responsible, found by turning them
  # off one at a time (drops per 5s: 78 as shipped):
  #
  # rules.lua blurs every quickshell:* layer, including three where the blur
  # can never be seen: the shell's own wallpaper window (full screen, opaque
  # over a still wallpaper and transparent but for the widgets over a video),
  # the 2px screen-frame strips and the screen corners. Excluding the
  # wallpaper window alone took it to 18, all three to 10. Nothing visible is
  # lost with a still wallpaper either, so they are excluded outright.
  #
  # new_optimizations caches the blurred background (background + bottom
  # layers) so that blurred surfaces above it sample the cache instead of
  # blurring again. The right trade for a still wallpaper, the wrong one for a
  # video: the cache goes stale every video frame, so every frame paid for a
  # full-screen blur per monitor however little of it anything blurred was
  # over. Off on top of the rules above: 0 drops on both monitors, with foot
  # and Dolphin tiled over the video and translucent (inactive_opacity 0.9).
  # It is off only while a video is set — switchwall.sh flips it when the
  # wallpaper changes, and general.lua re-derives it on every config load from
  # the restore script, the one file that records whether a video is set.
  # With it off, xray has no effect: a translucent floating window blurs the
  # windows behind it as well as the wallpaper.
  blurCache = on: "hyprctl eval 'hl.config({ decoration = { blur = { new_optimizations = ${lib.boolToString on} } } })' >/dev/null";

  patch = ''
    # Case. Upstream tests for a video by lowercase extension, but the
    # selector's folder model is case-insensitive, so a .MP4 would be listed
    # and then handed down the image path — matugen reading a video. One
    # spelling everywhere, the regex the rest of end4-pC (DesktopMenu,
    # BackgroundConfig, QuickConfig) already uses; switchwall.sh and the
    # thumbnail pass below lowercase too.
    before=$({ grep -rF 'endsWith(".mov")' $qs --include='*.qml' || true; } | wc -l)
    [ "$before" = "3" ] || { echo "video checks: expected 3 endsWith chains, found $before" >&2; exit 1; }
    grep -rlZF 'endsWith(".mov")' $qs --include='*.qml' | xargs -0 sed -i \
      's#\([A-Za-z_][A-Za-z0-9_.]*\)\.endsWith("\.mp4") || \1\.endsWith("\.webm") || \1\.endsWith("\.mkv") || \1\.endsWith("\.avi") || \1\.endsWith("\.mov")#/\\.(mp4|webm|mkv|avi|mov)$/i.test(\1)#g'
    [ "$({ grep -rF 'endsWith(".mov")' $qs --include='*.qml' || true; } | wc -l)" = "0" ] || exit 1
    [ "$({ grep -rF '/\.(mp4|webm|mkv|avi|mov)$/i.test(' $qs --include='*.qml' || true; } | wc -l)" -ge "3" ] || exit 1

    insert_after $qs/modules/common/Images.qml \
      '    readonly property list<string> validImageExtensions: ["jpg", "jpeg", "png", "webp", "avif", "bmp", "tif", "tiff", "svg"]' \
      ${videoQml.images} '    '

    # The selector: list videos, show their tiles as thumbnails, and have a
    # video tile ask for its thumbnail rather than sit on a file icon.
    substituteInPlace $qs/services/Wallpapers.qml \
      --replace-fail '    readonly property list<string> extensions: [ // TODO: add videos' \
                     '    readonly property list<string> extensions: [' \
      --replace-fail '"jpg", "jpeg", "png", "webp", "avif", "bmp", "svg"' \
                     '"jpg", "jpeg", "png", "webp", "avif", "bmp", "svg", "mp4", "webm", "mkv", "avi", "mov"'
    insert_after $qs/services/Wallpapers.qml \
      '    property string confirmedPath: ""  // Holds confirmed path until config catches up' \
      ${videoQml.wallpapers} '    '

    substituteInPlace $qs/modules/ii/wallpaperSelector/WallpaperDirectoryItem.qml \
      --replace-fail 'Images.isValidImageByName(fileModelData.fileName) : false' \
                     '(Images.isValidImageByName(fileModelData.fileName) || Images.isVideoByName(fileModelData.fileName)) : false'
    insert_after $qs/modules/ii/wallpaperSelector/WallpaperDirectoryItem.qml \
      '                        generateThumbnail: false' \
      ${videoQml.tile} '                        '

    # The thumbnail pass. It skipped videos outright; it now thumbnails their
    # frame, and makes sure the full-size frame exists for the preview. This is
    # the pass that actually runs here: its Python sibling, tried first, dies
    # on import (no GnomeDesktop typelib in the venv), so every thumbnail comes
    # from this script. GIFs are still skipped, as upstream.
    substituteInPlace $qs/scripts/thumbnails/generate-thumbnails-magick.sh \
      --replace-fail '        *.gif|*.mp4|*.webm|*.mkv|*.avi|*.mov)' '        *.gif)' \
      --replace-fail '    local encoded_path' '    local src_image="$abs_path"
        case "''${abs_path,,}" in
            *.mp4|*.webm|*.mkv|*.avi|*.mov) src_image="$(${videoFrame} "$abs_path")" || return 0 ;;
        esac
        local encoded_path' \
      --replace-fail 'magick "$abs_path" -resize' 'magick "$src_image" -resize'

    # The background: a video's picture is its own frame, not whatever
    # thumbnailPath the config holds (that is the *applied* wallpaper's, so a
    # previewed video showed the wrong one), and the window only goes
    # transparent over the video that is actually playing.
    #
    # Of the three upstream reveals, the one at the end of a transition goes
    # through the delay; startup and unlock stay immediate, as mpvpaper has
    # been running all along by then.
    B=$qs/modules/ii/background/Background.qml
    substituteInPlace $B \
      --replace-fail 'wallpaperIsVideo ? Config.options.background.thumbnailPath : bgRoot.effectiveWallpaperPath' \
                     'wallpaperIsVideo ? Images.videoFramePath(bgRoot.effectiveWallpaperPath) : bgRoot.effectiveWallpaperPath' \
      --replace-fail 'bgRoot.videoRevealed = bgRoot.wallpaperIsVideo' 'bgRoot.videoRevealed = bgRoot.videoIsLive' \
      --replace-fail '                if (!bgRoot.wallpaperIsVideo) return' '                if (!bgRoot.videoIsLive) return' \
      --replace-fail '                bgRoot.videoRevealed = true' '                videoRevealDelay.restart()' \
      --replace-fail 'wallpaperIsVideo: bgRoot.wallpaperIsVideo' 'wallpaperIsVideo: bgRoot.videoIsLive' \
      --replace-fail 'showBlur && !bgRoot.wallpaperIsVideo' 'showBlur && !bgRoot.videoIsLive'
    [ "$(grep -c '^                bgRoot.videoRevealed = bgRoot.videoIsLive$' $B)" = "1" ] || {
      echo "Background.qml: expected one reveal at the end of the transition" >&2
      exit 1
    }
    sed -i 's/^                bgRoot.videoRevealed = bgRoot.videoIsLive$/                if (bgRoot.videoIsLive) videoRevealDelay.restart()/' $B
    [ "$(grep -c 'bgRoot.videoRevealed = bgRoot.videoIsLive' $B)" = "2" ] || exit 1
    insert_after $B '        property bool videoRevealed: false' ${videoQml.background} '        '

    # The overview's workspace cards draw the wallpaper as-is, so with a video
    # they loaded the .mp4 as an image, failed, and showed the card's colour —
    # which upstream left as a debugging "red". The card gets the video's
    # frame, and a theme colour behind it for the moment it is loading.
    #
    # sourceSize because there are twenty cards (maxWorkspaces), each the
    # wallpaper at overview.scale (0.18 here, ~346x194), and without it they
    # were fed the full image — 1080p at best, the 16MB Escoffier PNG at
    # worst. They share one url, so at the cards' size it is one small decode.
    O=$qs/modules/ii/overview/NiriOverview.qml
    substituteInPlace $O \
      --replace-fail '                        color: "red"' '                        color: Appearance.colors.colLayer1' \
      --replace-fail '                            source: Config.options.background.wallpaperPath' \
                     '                            source: Images.isVideoByName(Config.options.background.wallpaperPath) ? Images.videoFramePath(Config.options.background.wallpaperPath) : Config.options.background.wallpaperPath
                                sourceSize: Qt.size(root.monitorW * root.scale, root.wsHeight)'
    [ "$(grep -c 'Images.videoFramePath' $O)" = "1" ] || exit 1

    # Settings' Desktop/Lockscreen pair and the desktop menu's wallpaper
    # strip picture a video by thumbnailPath, which is the *desktop* video's
    # frame — so a lock screen video, or any other video in the strip, showed
    # the desktop's. Each gets its own frame.
    for f in $qs/modules/ii/settings/pages/BackgroundConfig.qml $qs/modules/ii/desktopMenu/DesktopMenu.qml; do
      substituteInPlace "$f" \
        --replace-fail '            ? Config.options.background.thumbnailPath' '            ? Images.videoFramePath(path)'
    done

    # switchwall.sh: the reordered video branch (see videoSwitch), the video
    # the restore script that relaunches mpvpaper at login plays, scheme
    # detection reading the frame instead of the video, and is_video
    # case-insensitive.
    #
    # The per-output IPC socket is upstream's now (MPV_SOCKET_PREFIX, at the
    # same $XDG_RUNTIME_DIR/mpvpaper-<output>.sock this patch used to add), so
    # both video branches only keep calling it. MPVPAPER_FLAGS is emptied:
    # upstream passes `-p -a max`, and `-a` is new in mpvpaper 1.9 where nixpkgs
    # has 1.8 — which reports "invalid option" and then reads `max` as the
    # output name, so no wallpaper starts. `-p` alone would work, but it is the
    # auto-pause mpvpaperCtl says does nothing under Hyprland; pausing is done
    # by the shell over the socket instead.
    #
    # The 1080p30 copy (see videoProxy) is made in main(), before switch()
    # tears anything down, so the old wallpaper stays up for the length of a
    # conversion rather than going black — the selector shows the new video's
    # frame meanwhile. A conversion can take long enough to pick something
    # else in the middle of it, so every switch leaves its pid in a stamp and a
    # video switch that finds the stamp changed after converting exits instead
    # of overriding the newer pick. The restore script asks videoProxy by name,
    # once before its per-monitor loop, so a login after the cache was cleared
    # converts once rather than per monitor. A lock screen video is picked
    # through the colors-only lock mode, which only reads its frame; its copy
    # is started there in the background, so the first lock can play it.
    #
    # profile=fast: mpv's render pass went from 30% to 12% of the iGPU per
    # monitor with it, same video, nothing dropped either way. A 1080p video
    # on a 1080p screen is not scaled, so what it gives up is the dither.
    sed 's/^./            &/' ${videoSwitch.old} > $TMPDIR/switch-old
    sed 's/^./            &/' ${videoSwitch.new} > $TMPDIR/switch-new
    substituteInPlace $qs/scripts/colors/switchwall.sh \
      --replace-fail "$(cat $TMPDIR/switch-old)" "$(cat $TMPDIR/switch-new)" \
      --replace-fail 'video-align-y=0.5 load-scripts=no"' 'video-align-y=0.5 load-scripts=no profile=fast"' \
      --replace-fail '"\$monitor" "$video_path"' '"\$monitor" "\$video"' \
      --replace-fail 'MPVPAPER_FLAGS="-p -a max"' 'MPVPAPER_FLAGS=""' \
      --replace-fail '    switch "$imgpath" "$mode_flag"' '    if [[ -z "$colors_only_flag" ]]; then
            echo $$ > "$XDG_RUNTIME_DIR/ii-switchwall.latest"
            if is_video "$imgpath"; then
                ${videoProxy}/bin/ii-video-proxy "$imgpath" >/dev/null
                [ "$(cat "$XDG_RUNTIME_DIR/ii-switchwall.latest" 2>/dev/null)" = "$$" ] || exit 0
            fi
        elif [[ -n "$colors_lock_flag" ]] && is_video "$imgpath"; then
            ${pkgs.util-linux}/bin/setsid -f ${videoProxy}/bin/ii-video-proxy "$imgpath" >/dev/null 2>&1 < /dev/null
        fi
        switch "$imgpath" "$mode_flag"' \
      --replace-fail 'detected_type="$(detect_scheme_type_from_image "$imgpath")"' \
                     'detected_type="$(detect_scheme_type_from_image "$(is_video "$imgpath" && ${videoFrame} "$imgpath" || echo "$imgpath")")"' \
      --replace-fail '    local extension="''${1##*.}"' '    local extension="''${1##*.}"; extension="''${extension,,}"'
    [ "$(grep -c 'input-ipc-server=' $qs/scripts/colors/switchwall.sh)" = "2" ] || exit 1
    [ "$(grep -c '^MPVPAPER_FLAGS=""$' $qs/scripts/colors/switchwall.sh)" = "1" ] || exit 1
    # Inside create_restore_script's unquoted heredoc: \$( runs at login,
    # $video_path is the original, filled in when the script is written.
    printf '%s\n' 'video="\$(ii-video-proxy "$video_path" 2>/dev/null || echo "$video_path")"' > $TMPDIR/restore-video
    insert_after $qs/scripts/colors/switchwall.sh 'pkill -f -9 mpvpaper' $TMPDIR/restore-video ""
    [ "$(grep -c 'ii-video-proxy' $qs/scripts/colors/switchwall.sh)" = "4" ] || exit 1
    # The lock screen's own mpvpaper uses the same options (see videoOpts).
    grep -qxF 'VIDEO_OPTS="${videoOpts}"' $qs/scripts/colors/switchwall.sh || {
      echo "switchwall.sh: VIDEO_OPTS no longer matches videoOpts" >&2
      exit 1
    }

    # ── The restore script never ran on this machine.
    #
    # switchwall.sh writes it with a #!/bin/bash shebang, and NixOS has no
    # /bin/bash: execs.lua's exec failed with "bad interpreter" at every login,
    # silently, so a video wallpaper came back as an empty screen — the shell
    # goes transparent because the config says video, and nothing was playing
    # behind it. Both heredocs get /usr/bin/env, and execs.lua runs the script
    # through bash as well, because the script is in mutablePaths and one
    # written before this fix keeps its old shebang until the next video
    # wallpaper is applied.
    #
    # And the kill before each start was `pkill -f mpvpaper`, which matches the
    # word anywhere in any command line: the thumbnail pass's ffmpeg writing to
    # .../mpvpaper_thumbnails/, ii-mpvpaper-ctl, an editor with the file open.
    # Anchored on argv[0] it only matches mpvpaper itself. (Not -x: the
    # process is the wrapper's .mpvpaper-wrapp, which argv[0] still names.)
    substituteInPlace $qs/scripts/colors/switchwall.sh \
      --replace-fail '#!/bin/bash' '#!/usr/bin/env bash' \
      --replace-fail 'pkill -f -9 mpvpaper' "pkill -9 -f '^[^ ]*mpvpaper '"
    [ "$(grep -c '#!/bin/bash' $qs/scripts/colors/switchwall.sh || true)" = "0" ] || exit 1
    [ "$(grep -c "pkill -9 -f '^\[^ \]\*mpvpaper '" $qs/scripts/colors/switchwall.sh)" = "2" ] || exit 1
    substituteInPlace $out/.config/hypr/hyprland/execs.lua \
      --replace-fail 'hl.exec_cmd("$HOME/.config/hypr/custom/scripts/__restore_video_wallpaper.sh")' \
                     'hl.exec_cmd("bash $HOME/.config/hypr/custom/scripts/__restore_video_wallpaper.sh")'

    # ── Blur over a live wallpaper (see blurCache).
    #
    # The video branch turns the blur cache off (in videoSwitch); the image
    # branch, which is where upstream clears the restore script, turns it
    # back on. That remove_restore is the only one at this depth — the other
    # sits one level deeper, in the video branch's failure path.
    insert_after $qs/scripts/colors/switchwall.sh '                remove_restore' \
      ${pkgs.writeText "ii-video-switch-image" "${blurCache true}\n"} '                '
    [ "$(grep -c 'new_optimizations = ' $qs/scripts/colors/switchwall.sh)" = "2" ] || exit 1

    cat >> $out/.config/hypr/hyprland/rules.lua <<'IIRULES'

    -- No blur where it can never be seen; it made a video wallpaper stutter (NixOS config, ii-session.nix)
    hl.layer_rule({ match = { namespace = "quickshell:background" }, blur = false })
    hl.layer_rule({ match = { namespace = "quickshell:screenframe" }, blur = false })
    hl.layer_rule({ match = { namespace = "quickshell:screenCorners" }, blur = false })
    IIRULES

    cat >> $out/.config/hypr/hyprland/general.lua <<'IIGENERAL'

    -- No blur cache while a video wallpaper is set: it goes stale every video frame (NixOS config, ii-session.nix)
    local restore = io.open(HOME .. "/.config/hypr/custom/scripts/__restore_video_wallpaper.sh", "r")
    if restore then
        local script = restore:read("*a") or ""
        restore:close()
        if script:find("mpvpaper -o", 1, true) then
            hl.config({ decoration = { blur = { new_optimizations = false } } })
        end
    end
    IIGENERAL
  '';
}
