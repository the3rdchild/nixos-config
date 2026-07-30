{ pkgs, lib, ... }:
{
  # Docker tetap terinstall & bisa dipakai, tapi TIDAK auto-start saat boot.
  # Nyalakan saat butuh dengan:  sudo systemctl start docker
  virtualisation.docker.enable = true;

  # Cegah systemd auto-start docker service & socket saat boot, dan cegah
  # socket-activation (agar container/VM tidak jalan otomatis).
  systemd.services.docker.wantedBy = lib.mkForce [ ];
  systemd.sockets.docker.wantedBy = lib.mkForce [ ];

  virtualisation.docker.rootless = {
    enable = true;
    setSocketVariable = true;
  };
  users.users.noouoops.extraGroups = [ "docker" ];
}
