{ pkgs, lib, ... }:
let
  zen = "app.zen_browser.zen.desktop";
  micro = "micro-kitty.desktop";
  ark = "org.kde.ark.desktop";

  # The plain 7zip package strips the RAR codec (unRAR licence), so listing
  # works but extraction doesn't. _7zz-rar keeps it, which is why it needs
  # allowUnfree. It installs `7zz` only, and Ark's cli7z plugin looks for a
  # binary named exactly `7z` (no `7zz` in its strings), so without the alias
  # Ark still says "No suitable plugin found".
  sevenZip = pkgs.symlinkJoin {
    name = "7zz-rar-with-7z-alias";
    paths = [ pkgs._7zz-rar ];
    postBuild = "ln -s 7zz $out/bin/7z";
  };

  assoc = app: types: lib.genAttrs types (_: [ app ]);
in
{
  # Dolphin's "Open with" dialog was empty and every double-click fell back to
  # it. KService (kbuildsycoca6) only indexes .desktop files reachable from an
  # XDG menu, and with plasma6 gone nothing ships applications.menu anymore.
  # This minimal menu includes every desktop entry from $XDG_DATA_DIRS.
  xdg.configFile."menus/applications.menu".text = ''
    <!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
     "http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">
    <Menu>
      <Name>Applications</Name>
      <DefaultAppDirs/>
      <DefaultDirectoryDirs/>
      <DefaultMergeDirs/>
      <Include><All/></Include>
    </Menu>
  '';

  # Ark has no RAR support of its own ("No suitable plugin found"): its rar
  # plugin wants rar/unrar, its cli7z plugin wants a 7z binary on PATH. Ark's
  # own Dolphin menu entries (Extract/Compress) only list the formats it can
  # handle, so RAR shows up there once sevenZip is installed.
  home.packages = [
    pkgs.kdePackages.ark
    sevenZip
  ];

  # micro has no .desktop file of its own; run it inside kitty.
  xdg.desktopEntries.micro-kitty = {
    name = "Micro (kitty)";
    exec = "kitty micro %F";
    terminal = false;
    icon = "accessories-text-editor";
    mimeType = [ "text/plain" ];
  };

  # Dolphin right-click → "Open with VS Code", for files and folders. KIO
  # refuses service menus that aren't executable. Launched through `uwsm app`
  # like SUPER+SHIFT+V, into its own app-Hyprland-code-<hex>.scope, so the
  # memory cap in ./app-limits.nix still applies.
  xdg.dataFile."kio/servicemenus/open-with-code.desktop" = {
    executable = true;
    text = ''
      [Desktop Entry]
      Type=Service
      MimeType=all/all;inode/directory;
      Actions=openWithCode;
      X-KDE-Priority=TopLevel

      [Desktop Action openWithCode]
      Name=Open with VS Code
      Icon=vscode
      Exec=${pkgs.uwsm}/bin/uwsm app -- code %F
    '';
  };

  # Dolphin right-click → "Open in Local Web Player": opens the folder (or a
  # file's parent folder) in Zen. The player (formerly /mnt/doc/local-web-player,
  # not in the TEAM SSD backup — only local-web-player-win survived) loads
  # a path from the URL hash — see public/js/main.js, `fromHash`.
  xdg.dataFile."kio/servicemenus/open-in-web-player.desktop" = {
    executable = true;
    text =
      let
        open = pkgs.writeShellScript "open-in-web-player" ''
          p="$1"
          [ -d "$p" ] || p="$(dirname "$p")"
          hash="$(${pkgs.python3}/bin/python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/"))' "$p")"
          exec flatpak run app.zen_browser.zen "http://localhost:4321/#$hash"
        '';
      in
      ''
        [Desktop Entry]
        Type=Service
        MimeType=all/all;inode/directory;
        Actions=openInWebPlayer;
        X-KDE-Priority=TopLevel

        [Desktop Action openInWebPlayer]
        Name=Open in Local Web Player
        Icon=multimedia-player
        Exec=${open} %f
      '';
  };

  # Dolphin right-click on a .rar/.7z → "Extract here with 7-Zip", into a
  # folder named after the archive (" (2)", " (3)"… if that exists). Independent
  # of Ark, so it still works if Ark's plugin lookup ever misses the binary.
  # Encrypted archives get a kdialog password prompt, repeated until it is
  # right or cancelled. 7zz asks "Enter password:" on stdin when none is given
  # and errors "Wrong password" when it is bad; both are matched below.
  xdg.dataFile."kio/servicemenus/extract-with-7zip.desktop" = {
    executable = true;
    text =
      let
        extract = pkgs.writeShellScript "extract-with-7zip" ''
          sz=${sevenZip}/bin/7zz
          ask=${pkgs.kdePackages.kdialog}/bin/kdialog
          notify=${pkgs.libnotify}/bin/notify-send

          for f in "$@"; do
            name=$(basename "$f")
            # Extract into a scratch dir beside the archive and rename it on
            # success, so a wrong password never leaves half-written files in
            # the real destination. mktemp makes it 0700; give it back the
            # umask-default mode it would have had.
            tmp=$(mktemp -d "$(dirname "$f")/.extract-XXXXXX") || {
              $notify -i dialog-error 7-Zip "Cannot write next to $name"
              continue
            }
            chmod "$(printf '%03o' $((0777 & ~$(umask))))" "$tmp"

            pw=""
            prompt="Password for $name:"
            while :; do
              # The password goes in on stdin, not -p, so it never shows in ps.
              if out=$(printf '%s\n' "$pw" | $sz x -y -o"$tmp" -- "$f" 2>&1); then
                dest="''${f%.*}"
                n=2
                while [ -e "$dest" ]; do
                  dest="''${f%.*} ($n)"
                  n=$((n + 1))
                done
                mv -- "$tmp" "$dest"
                break
              fi
              find "$tmp" -mindepth 1 -delete
              if printf '%s' "$out" | grep -qE 'Enter password|Wrong password'; then
                pw=$($ask --title 7-Zip --password "$prompt") || { rmdir "$tmp"; break; }
                prompt="Wrong password for $name. Try again:"
              else
                $notify -i dialog-error 7-Zip "Failed to extract $name"
                rmdir "$tmp"
                break
              fi
            done
          done
        '';
      in
      ''
        [Desktop Entry]
        Type=Service
        MimeType=application/vnd.rar;application/x-rar;application/x-7z-compressed;
        Actions=extractWith7zip;
        X-KDE-Priority=TopLevel

        [Desktop Action extractWith7zip]
        Name=Extract here with 7-Zip
        Icon=archive-extract
        Exec=${extract} %F
      '';
  };

  # Dolphin's "Open Terminal Here" (ALT+SHIFT+F4) reads the terminal from
  # kdeglobals and fell back to xterm. KDE apps rewrite kdeglobals at runtime
  # (colour scheme, accent), so only these two keys are set, not the file.
  home.activation.kdeTerminal = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 --file kdeglobals --group General --key TerminalApplication kitty
    run ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 --file kdeglobals --group General --key TerminalService kitty.desktop
  '';

  # Overwrites the old hand-edited ~/.config/mimeapps.list (kept as .backup).
  xdg.mimeApps = {
    enable = true;
    defaultApplications =
      assoc zen [
        "application/pdf"
        "image/png"
        "image/jpeg"
        "image/gif"
        "image/webp"
        "image/svg+xml"
        "image/avif"
        "image/bmp"
        # Zen plays web formats only; mkv/avi are left unassigned.
        "video/mp4"
        "video/webm"
        "video/ogg"
        "audio/mpeg"
        "audio/ogg"
        "audio/flac"
        "audio/wav"
        "audio/x-wav"
        "audio/mp4"
        "audio/aac"
        "audio/opus"
      ]
      // assoc "writer.desktop" [
        "application/msword"
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "application/vnd.oasis.opendocument.text"
        "application/rtf"
      ]
      // assoc "calc.desktop" [
        "application/vnd.ms-excel"
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        "application/vnd.oasis.opendocument.spreadsheet"
        "text/csv"
      ]
      // assoc "impress.desktop" [
        "application/vnd.ms-powerpoint"
        "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        "application/vnd.oasis.opendocument.presentation"
      ]
      // assoc ark [
        "application/zip"
        "application/x-tar"
        "application/x-compressed-tar"
        "application/x-bzip2-compressed-tar"
        "application/x-xz-compressed-tar"
        "application/zstd"
        "application/x-7z-compressed"
        "application/vnd.rar"
        "application/gzip"
      ]
      // assoc micro [
        "text/plain"
        "text/markdown"
        "text/x-nix"
        "application/json"
        "application/x-yaml"
        "application/toml"
        "application/x-shellscript"
        "text/x-python"
        "application/xml"
      ]
      // {
        # Unset, xdg-open on a folder fell through mimeinfo.cache to kitty-open.
        "inode/directory" = [ "org.kde.dolphin.desktop" ];
        "x-scheme-handler/http" = [ zen ];
        "x-scheme-handler/https" = [ zen ];
        "x-scheme-handler/about" = [ zen ];
        "x-scheme-handler/unknown" = [ zen ];
        "text/html" = [ zen ];
        "application/xhtml+xml" = [ zen ];
        "x-scheme-handler/claude-cli" = [ "claude-code-url-handler.desktop" ];
        "x-scheme-handler/heroic" = [ "com.heroicgameslauncher.hgl.desktop" ];
      };
  };
}
