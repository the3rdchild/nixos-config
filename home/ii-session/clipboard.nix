# ── Clipboard: picking an entry pastes it.
#
# Two upstream problems. Cliphist.paste() exists but its classic-cliphist
# branch ends in `wl-copy && wl-paste`, and wl-paste only prints the
# clipboard to stdout — it does not press anything; the Stash branch right
# below it correctly runs pressPasteCommand. And the launcher's clipboard
# entries call copy(), never paste(), so selecting one left you to hit
# Ctrl+V yourself.
#
# pressPasteCommand is `ydotool key -d 1 29:1 47:1 47:0 29:0` — Ctrl down,
# V down, V up, Ctrl up. Being a keystroke rather than a data transfer, it
# is format-agnostic: images and anything else the clipboard holds paste
# the same way. ydotoold is already running (programs.ydotool.enable in
# ../../modules/hyprland-desktop.nix) and the user is in the ydotool group.
{ ... }: {
  patch = ''
    for f in $out/.config/quickshell/*/services/Cliphist.qml; do
      [ -e "$f" ] || continue
      substituteInPlace "$f" --replace-fail \
        'decode | wl-copy && wl-paste`]);' \
        'decode | wl-copy && sleep ''${root.pasteDelay} && ''${root.pressPasteCommand}`]);'
    done

    # Only the entry's primary action — the first Cliphist.copy call in the
    # file. ii lists an explicit "Copy" action beside it (a second call), which
    # must stay copy-only; that is the whole point of having it. end4-pC
    # swapped that action for Pin/Unpin, so it has the one call and nothing
    # left to protect.
    #
    # `0,/re/s//x/` replaces the first match and nothing else, which a
    # --replace-fail anchor cannot express.
    for f in $out/.config/quickshell/*/services/LauncherSearch.qml; do
      [ -e "$f" ] || continue
      case "$f" in
        */quickshell/ii/*) want=2 ;;
        *) want=1 ;;
      esac
      before=$(grep -c 'Cliphist\.copy(entry);' "$f")
      [ "$before" = "$want" ] || { echo "$f: expected $want Cliphist.copy call sites, found $before" >&2; exit 1; }
      sed -i '0,/Cliphist\.copy(entry);/s//Cliphist.paste(entry);/' "$f"
      grep -q 'Cliphist\.paste(entry);' "$f"
      [ "$(grep -c 'Cliphist\.copy(entry);' "$f")" = "$((want - 1))" ] || exit 1
    done
  '';
}
