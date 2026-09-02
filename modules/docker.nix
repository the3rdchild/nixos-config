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
    # DNS untuk container di bridge network: pakai DNS bawaan slirp4netns
    # (10.0.2.3), yang meneruskan query ke stub systemd-resolved host
    # (127.0.0.53) lalu keluar via DoT. Tanpa ini dockerd menyalin upstream
    # plaintext (1.1.1.1 dsb) ke resolv.conf container, dan query-nya
    # di-REJECT oleh dns-leak-guard (modules/network.nix). Tidak berpengaruh
    # ke container --network host.
    daemon.settings = { dns = [ "10.0.2.3" ]; };
  };
  users.users.noouoops.extraGroups = [ "docker" ];
}
