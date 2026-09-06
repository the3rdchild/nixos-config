# Android phone storage via USB (MTP), auto-mounted at /mnt/phone.
#
# Problem this solves:
#   Plugging in an Android phone does NOT expose a block device. In "File
#   transfer" mode the phone speaks MTP (Media Transfer Protocol) over USB,
#   which udisks2 (see automount.nix) deliberately ignores — udisks2 only
#   mounts filesystems on block devices. On top of that, the POCO X3 NFC
#   (MIUI) re-enumerates its USB configuration every time an MTP session
#   OPENS (kernel log shows ff48 → ff08 → ff48 flaps within ~6s), so:
#     * a client that opens a session mid-flap gets an empty/dead mount
#       (Dolphin: "Loading canceled" or "udi=... does not exist"),
#     * two clients holding sessions at once kick each other off in a
#       re-enumeration loop (device number keeps climbing in lsusb).
#
# Approach (same spirit as automount.nix, but for MTP):
#   1. libmtp's udev rules tag MTP devices (ID_MTP_DEVICE=1). Generic — any
#      Android phone / MTP media player matches, not just this one.
#   2. A udev rule ties the device's systemd device unit to
#      mtp-automount.service (SYSTEMD_WANTS, SYSTEM manager), which mounts
#      the phone with simple-mtpfs at /mnt/phone the moment it appears
#      (coldplug included).
#   3. The service runs a flap-tolerant script:
#        mount → verify with a real listing → retry up to 5×, 3s apart
#      winning the session-open lottery. simple-mtpfs then holds the ONLY
#      MTP session, which keeps the phone stable afterwards.
#
# Why /mnt/phone and not a user-session gvfs mount:
#   * /mnt is bind-mounted rslave into the local-web-player Docker
#     container, so the FUSE mount there propagates automatically — the
#     player's drive list (lib/filesystem.js listDrives()) picks it up with
#     no code changes, no container restart, on every re-plug. A gvfs mount
#     under /run/user/<uid>/gvfs is unreachable from the container.
#   * gvfs mounts are per-login-session; a system service outlives them.
#   * Every app (Dolphin folder view, terminal, vscode, the player) uses the
#     same path — ONE session holder, so no session wars.
#   * Writes: simple-mtpfs WRITE fails with EIO on this phone (MIUI). For
#     read-only consumers (player, copying files OFF) that's fine. To write
#     TO the phone, stop this service first and use the gvfs path:
#        systemctl stop mtp-automount && fusermount3 -u /mnt/phone
#        gio mount "mtp://Xiaomi_POCO_X3_NFC_a9cb098d/"   # rw, verified
#
# Phone-side requirements (not fixable from NixOS):
#   * Unlock the screen — MTP refuses locked devices.
#   * Set the USB mode to "File transfer / MTP" when prompted. Android
#     defaults to "Charging only", which exposes nothing at all.
#
# Alternatives considered / available in nixpkgs:
#   * go-mtpfs, android-file-transfer (aft-mtp-mount) — drop-in FUSE
#     alternates; same flapping applies (it's the phone, not the client).
#   * kdePackages.kio-fuse — bridges mtp:/ KIO URLs to FUSE; would add a
#     second session holder, skip.
#   * programs.adb.enable — rock-solid `adb push/pull` on Xiaomi; add if
#     CLI transfers become the norm.
{ config, pkgs, lib, ... }:
let
  mountpoint = "/mnt/phone";
  owner = "noouoops"; # uid 1000 — matches the fusermount ownership rule

  # Flap-tolerant MTP mounter. simple-mtpfs self-daemonizes on success, so
  # the oneshot service exits while the FUSE daemon keeps holding the
  # session. A mount that raced the USB re-enumeration comes up EMPTY, so
  # verification lists the root and retries on empty. Stale mounts from an
  # unplug (dead daemon → ENOTCONN) are lazily unmounted first.
  mtp-automount = pkgs.writeShellScriptBin "mtp-automount" ''
    set -u
    tries=5
    settle=3   # phone re-enumerates ~1-6s after an aborted session
    fusermount=${pkgs.fuse3}/bin/fusermount3
    mountpoint_bin=${pkgs.util-linux}/bin/mountpoint
    timeout=${pkgs.coreutils}/bin/timeout
    ls=${pkgs.coreutils}/bin/ls

    # Clear a stale mount from the previous unplug.
    if $mountpoint_bin -q ${mountpoint}; then
      echo "mtp-automount: stale mount — lazy unmounting"
      $fusermount -uz ${mountpoint} 2>/dev/null || true
      sleep 1
    fi

    i=0
    while [ "$i" -lt "$tries" ]; do
      i=$((i + 1))
      echo "mtp-automount: attempt $i/$tries"
      if ${pkgs.simple-mtpfs}/bin/simple-mtpfs ${mountpoint}; then
        entries=$($timeout 8 $ls ${mountpoint} 2>/dev/null || true)
        if [ -n "$entries" ]; then
          echo "mtp-automount: mounted ${mountpoint} (attempt $i)"
          exit 0
        fi
        echo "mtp-automount: mount came up empty — flap race, retrying"
        $fusermount -uz ${mountpoint} 2>/dev/null || true
      fi
      sleep "$settle"
    done
    echo "mtp-automount: giving up after $tries attempts"
    exit 1
  '';
in
{
  # --- 1. MTP device tagging (any MTP-capable device) -----------------------
  services.udev.packages = [ pkgs.libmtp ];

  # --- 2. Trigger the automount service when an MTP device appears ----------
  # SYSTEMD_WANTS on the SYSTEM device unit — the mount is a system path, so
  # no dependency on a login session. extraRules land in 99-local.rules,
  # safely after 69-libmtp.rules has set ID_MTP_DEVICE on the same uevent.
  services.udev.extraRules = ''
    ACTION=="add|change", \
      SUBSYSTEM=="usb", \
      ENV{ID_MTP_DEVICE}=="1", \
      TAG+="systemd", \
      ENV{SYSTEMD_WANTS}+="mtp-automount.service"
  '';

  # fusermount only lets a user mount over a directory they own, so the
  # mountpoint is pre-created (and kept) by tmpfiles.
  systemd.tmpfiles.rules = [ "d ${mountpoint} 0755 ${owner} users -" ];

  # --- 3. The automount itself ----------------------------------------------
  # Runs as the desktop user: FUSE mounts must be owned by a real user, and
  # that same uid (1000) is what the rootless-Docker player container maps
  # its root to, so the container can read the mounted files.
  #
  # Type=oneshot WITHOUT RemainAfterExit, but with KillMode=process:
  #   * oneshot+no-RemainAfterExit → the unit goes inactive when the script
  #     exits, so the next plug-in can retrigger it (stale mount from the
  #     unplug is cleaned by the script's first step);
  #   * KillMode=process → when the unit goes inactive systemd kills ONLY
  #     the (already-exited) main process, letting the self-daemonized
  #     simple-mtpfs keep holding the FUSE mount in the shared root mount
  #     namespace. With the default control-group KillMode the daemon would
  #     be reaped the instant the oneshot completes and the mount would
  #     evaporate. No ProtectSystem/PrivateTmp hardening either — any
  #     private mount namespace would swallow the mount.
  systemd.services.mtp-automount = {
    description = "Auto-mount MTP (Android) device at ${mountpoint}";
    after = [ "systemd-tmpfiles-setup.service" ];
    unitConfig = {
      # An unplugged phone burns through the default start-rate limit
      # harmlessly; don't let it lock the unit until reboot.
      StartLimitIntervalSec = 0;
    };
    serviceConfig = {
      Type = "oneshot";
      User = owner;
      Group = "users";
      KillMode = "process";
      ExecStart = "${mtp-automount}/bin/mtp-automount";
      Restart = "on-failure";
      RestartSec = "5";
    };
  };

  # --- 4. Supporting packages -----------------------------------------------
  # gvfs kept for its OTHER backends (trash://, network, PTP cameras in GTK
  # apps) and as the verified-rw manual write path (see header). Its MTP
  # automount is unused here on purpose — one session holder only.
  services.gvfs.enable = true;

  environment.systemPackages = with pkgs; [
    simple-mtpfs # manual reads / --list-devices (WRITE path fails on the
                 # POCO X3 NFC — see header for the gvfs write procedure)
  ];
}

