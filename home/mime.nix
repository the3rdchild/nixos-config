{ pkgs, lib, ... }:
let
  zen = "app.zen_browser.zen.desktop";
  micro = "micro-kitty.desktop";
  ark = "org.kde.ark.desktop";

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

  home.packages = [ pkgs.kdePackages.ark ];

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
