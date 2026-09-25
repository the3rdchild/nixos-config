{ config, pkgs, lib, ... }:
let
  docker = config.virtualisation.docker.rootless.package;
in
{
  # ── Nix store: garbage collection.
  #
  # options was "--max-old-generations 2", which is not a nix-collect-garbage
  # flag. It has never existed; the only ones that gate on age or count are
  # --delete-old, --delete-older-than and --max-freed. So the daily timer fired,
  # nix-collect-garbage rejected the argument, and the unit failed — every day,
  # silently, since the setting was written:
  #
  #   nix-gc-start[284768]: error: unrecognised flag '--max-old-generations'
  #   nix-gc.service: Failed with result 'exit-code'.
  #
  # Nothing was ever collected. By 2026-08-11 that had accumulated 108 system
  # generations and 103 GB of store across 53122 paths, against 29 GB actually
  # needed by the five newest generations plus home-manager. Roughly 74 GB of
  # the store was unreachable garbage that the daily job was supposed to have
  # taken and never did.
  #
  # The window was 30d while the i915/nvidia_drm initrd deadlock (Aug 2026)
  # was being bisected across generations. That is long settled, and with
  # several rebuilds a day 30d still held 106 generations on 2026-09-25. 7d
  # keeps a week of rollback, which in practice is well over 15 generations.
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };

  # ── Nix store: dedupe.
  #
  # Hard-links identical files as each path is added, so successive
  # generations of the same packages stop paying for the same bytes twice.
  # It only acts on new paths; the existing store was deduped once by hand
  # with `sudo nix-store --optimise` on 2026-09-25.
  nix.settings.auto-optimise-store = true;

  # ── Docker (rootless): prune unused images and build cache weekly.
  #
  # Docker here is rootless (modules/docker.nix), with its data in
  # ~/.local/share/docker under the user's own daemon. virtualisation.docker.
  # autoPrune only drives the rootful daemon, so it would prune nothing; this
  # is the user-level equivalent. On 2026-09-25 that directory held 33 GB, of
  # which ~25 GB was build cache with nothing active.
  #
  # Containers and volumes are left alone on purpose: a stopped container or a
  # volume can hold data, while images and build cache can always be pulled or
  # rebuilt. Only what has been unused for over a week goes, so images from a
  # current project survive between builds.
  systemd.user.services.docker-prune = {
    description = "Prune unused rootless Docker images and build cache";
    after = [ "docker.service" ];
    # Don't start dockerd just to prune; skip the run if it isn't up.
    unitConfig.ConditionPathExists = "%t/docker.sock";
    environment.DOCKER_HOST = "unix://%t/docker.sock";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = [
        "${docker}/bin/docker image prune --all --force --filter until=168h"
        "${docker}/bin/docker builder prune --all --force --filter until=168h"
      ];
    };
  };

  systemd.user.timers.docker-prune = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };
}
