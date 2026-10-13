# micro: follow the session's light/dark mode.
#
# Unlike kitty, micro is unmanaged by home-manager (../home/packages.nix only
# installs the binary) and gets no config root of its own in ./ii-session —
# whichever root it runs under (~/.config or ~/.config-ii) just accumulates
# whatever micro itself wrote there. So, unlike ./kitty-theme-settings.nix,
# this watcher applies to both roots: the dconf database is shared between
# them (see sharedFromConfigHome in ./ii-session/default.nix), and there is
# no wallpaper-driven theme already covering either one to collide with.
{ config, pkgs, lib, ... }:
let
  themeSettings = import ./micro-theme-settings.nix { inherit pkgs; };

  themeSync = pkgs.writeShellScript "micro-theme-sync" ''
    export PATH="${pkgs.dconf}/bin:$PATH"
    iface=/org/gnome/desktop/interface

    apply() {
      for root in "$HOME/.config" "$HOME/.config-ii"; do
        XDG_CONFIG_HOME="$root" ${themeSettings}/bin/micro-theme-settings
      done
    }

    apply
    dconf watch $iface/ | while read -r line; do
      [ "$line" = "$iface/color-scheme" ] && apply
    done

    # Only reached if `dconf watch` died; fail so systemd restarts it.
    exit 1
  '';
in {
  home.packages = [ themeSettings ];

  home.activation.microTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${themeSettings}/bin/micro-theme-settings
    XDG_CONFIG_HOME="${config.home.homeDirectory}/.config-ii" run ${themeSettings}/bin/micro-theme-settings
  '';

  systemd.user.services.micro-theme-sync = {
    Unit = {
      Description = "Write micro's light/dark colorscheme when the session mode changes";
      After = [ "dconf.service" ];
    };
    Service = {
      ExecStart = "${themeSync}";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
