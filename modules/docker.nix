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
    daemon.settings = {
      # DNS untuk container di bridge network: pakai DNS bawaan slirp4netns
      # (10.0.2.3), yang meneruskan query ke stub systemd-resolved host
      # (127.0.0.53) lalu keluar via DoT. Tanpa ini dockerd menyalin upstream
      # plaintext (1.1.1.1 dsb) ke resolv.conf container, dan query-nya
      # di-REJECT oleh dns-leak-guard (modules/network.nix). Tidak berpengaruh
      # ke container --network host.
      dns = [ "10.0.2.3" ];

      # Tarik image Docker Hub lewat cache Google, bukan langsung.
      #
      # registry-1.docker.io tidak bisa dijangkau dari jaringan ini: DNS-nya
      # normal dan auth.docker.io jabat tangan TLS dalam 0,12 detik, tapi
      # registry-nya sendiri timeout di IPv4 maupun IPv6 - dari empat IP yang
      # diresolusikan hanya satu yang menjawab, itu pun 4,5 detik. Akibatnya
      # `docker compose build` gagal di image yang belum ada di cache lokal
      # dengan "net/http: TLS handshake timeout", sementara image yang
      # kebetulan sudah tertarik lolos begitu saja - jadi gagalnya tampak acak.
      #
      # mirror.gcr.io menjawab dalam 0,15 detik dan melayani seluruh image
      # publik Docker Hub, bukan cuma `library/*` (sudah diuji dengan
      # oven/bun dan mikefarah/yq). Ia hanya berlaku untuk tarikan docker.io;
      # registry lain (ghcr.io, public.ecr.aws) tetap lewat jalur biasa.
      registry-mirrors = [ "https://mirror.gcr.io" ];
    };
  };
  users.users.noouoops.extraGroups = [ "docker" ];
}
