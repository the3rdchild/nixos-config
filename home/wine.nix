{ pkgs, ... }:
let
  wine = pkgs.wineWow64Packages.stable;

  # Japanese visual novels get their code page (932, Shift-JIS) from the locale
  # Wine starts under, and the system only builds en_US (modules/locales.nix).
  # Carrying ja_JP in a private locale archive keeps that out of the system
  # config; it is only exported for the "Japanese locale" action below.
  jaLocales = pkgs.glibcLocales.override {
    allLocales = false;
    locales = [ "ja_JP.UTF-8/UTF-8" "en_US.UTF-8/UTF-8" ];
  };

  # wine-run <wine|wine-ja|proton> FILE...
  #
  # One prefix per mode, made on first use under ~/.local/share/wineprefixes
  # (~0.5 GB each) and shared by every app run in that mode, so a small
  # utility doesn't cost a prefix of its own. The ja prefix is separate because
  # wineboot records the locale it was created under.
  run = pkgs.writeShellScript "wine-run" ''
    export PATH=${wine}/bin:${pkgs.libnotify}/bin:$PATH
    export WINEDEBUG=-all

    mode=$1; shift
    root="''${XDG_DATA_HOME:-$HOME/.local/share}/wineprefixes"
    log="$root/last-run.log"
    mkdir -p "$root"
    : > "$log"

    case $mode in
      wine) ;;
      wine-ja)
        # glibc here reads LOCALE_ARCHIVE_2_27; plain LOCALE_ARCHIVE is ignored
        # and Wine then silently starts under "C" (chcp prints 0, not 932).
        export LOCALE_ARCHIVE_2_27=${jaLocales}/lib/locale/locale-archive
        export LC_ALL=ja_JP.UTF-8 LANG=ja_JP.UTF-8
        ;;
      proton)
        # umu fetches its Proton and the Steam runtime on first use.
        export GAMEID=0 PROTONPATH=UMU-Latest
        ;;
    esac
    export WINEPREFIX="$root/$mode"

    if [ "$mode" != proton ] && [ ! -d "$WINEPREFIX" ]; then
      notify-send -i wine "Wine" "Creating the $mode prefix (first run only)…"
      # Without the overrides wineboot stops to offer a Mono/Gecko download.
      # Dropped again for the app itself, so a .NET app still gets asked.
      WINEDLLOVERRIDES="mscoree,mshtml=" wine wineboot -u >>"$log" 2>&1
      if [ "$mode" = wine-ja ]; then
        # Games ask for the Windows Japanese fonts by name; with none installed
        # the glyphs come out as empty boxes. Point them at Noto CJK
        # (modules/fonts.nix).
        key='HKCU\Software\Wine\Fonts\Replacements'
        for n in "MS Gothic" "MS PGothic" "MS UI Gothic" "Meiryo" "Meiryo UI" "Yu Gothic"; do
          wine reg add "$key" /v "$n" /d "Noto Sans CJK JP" /f >>"$log" 2>&1
        done
        for n in "MS Mincho" "MS PMincho" "Yu Mincho"; do
          wine reg add "$key" /v "$n" /d "Noto Serif CJK JP" /f >>"$log" 2>&1
        done
      fi
    fi

    for f in "$@"; do
      cd "$(dirname "$f")" || continue   # games load assets relative to cwd
      case "''${f,,}" in
        *.msi)        cmd=(msiexec /i "$f") ;;
        *.bat|*.cmd)  cmd=(cmd /c "$f") ;;
        *)            cmd=("$f") ;;
      esac
      if [ "$mode" = proton ]; then
        cmd=(${pkgs.umu-launcher}/bin/umu-run "''${cmd[@]}")
      else
        cmd=(wine "''${cmd[@]}")
      fi
      (
        SECONDS=0
        "''${cmd[@]}" >>"$log" 2>&1
        rc=$?
        # Windows programs exit non-zero for ordinary reasons; only a quick
        # failure is a start-up problem worth interrupting for.
        if [ $rc -ne 0 ] && [ $SECONDS -lt 5 ]; then
          notify-send -i dialog-error "Wine" "$(basename "$f") exited with code $rc. Log: $log"
        fi
      ) &
    done
    wait
  '';
in
{
  # winetricks is for what a prefix lacks (cjkfonts, directx, dotnet…).
  home.packages = [
    wine
    pkgs.winetricks
    pkgs.umu-launcher
  ];

  # Dolphin right-click on a Windows program → Windows ▸ Run with …
  # Through `uwsm app` like the other menus in ./mime.nix, so each run lands in
  # its own scope; no memory cap is set for it in ./app-limits.nix, on purpose:
  # a game shouldn't be killed at an editor's 2 GB.
  xdg.dataFile."kio/servicemenus/run-windows.desktop" = {
    executable = true;
    text = ''
      [Desktop Entry]
      Type=Service
      MimeType=application/vnd.microsoft.portable-executable;application/x-dosexec;application/x-msdownload;application/x-msi;application/x-bat;
      Actions=runWine;runWineJa;runProton;
      X-KDE-Submenu=Windows

      [Desktop Action runWine]
      Name=Run with Wine
      Icon=wine
      Exec=${pkgs.uwsm}/bin/uwsm app -- ${run} wine %F

      [Desktop Action runWineJa]
      Name=Run with Wine (Japanese locale)
      Icon=wine
      Exec=${pkgs.uwsm}/bin/uwsm app -- ${run} wine-ja %F

      [Desktop Action runProton]
      Name=Run with Proton (umu)
      Icon=steam
      Exec=${pkgs.uwsm}/bin/uwsm app -- ${run} proton %F
    '';
  };
}
