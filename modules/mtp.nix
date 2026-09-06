# Android phone storage via USB (MTP), auto-mounted at ~/mnt/phone.
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
#   2. A udev rule ties the device's systemd *user* device unit to
#      mtp-automount.service (SYSTEMD_USER_WANTS), so the mount happens for
#      the logged-in user the moment the phone is plugged (coldplug too).
#   3. mtp-automount.service runs a flap-tolerant script:
#        gio mount → verify with a real listing → retry up to 5×, 3s apart
#      winning the session-open lottery. gvfsd then holds the ONLY MTP
#      session, which keeps the phone stable afterwards.
#   4. ~/mnt/phone is a symlink to the gvfs FUSE mount
#      (/run/user/1000/gvfs/mtp:host=...), so every app gets a plain,
#      stable path — Dolphin (as a folder), terminal, vscode, scripts.
#      NOTE: access it ONLY through ~/mnt/phone. Opening Dolphin's sidebar
#      phone entry (or mtp:/ URLs) starts a SECOND session and re-triggers
#      the flap war.
#
#   Why gvfs and not a FUSE client like simple-mtpfs: on this phone (MIUI,
#   SD-card storage) simple-mtpfs READS work but every WRITE fails with
#   EIO and kills the session, while gvfs writes are verified rw. gvfsd
#   also auto-unmounts on unplug, so no stale-mount cleanup is needed.
#
# Phone-side requirements (not fixable from NixOS):
#   * Unlock the screen — MTP refuses locked devices.
#   * Set the USB mode to "File transfer / MTP" when prompted. Android
#     defaults to "Charging only", which exposes nothing at all.
#
# Alternatives considered / available in nixpkgs:
#   * kdePackages.kio-fuse — bridges mtp:/ KIO URLs to FUSE for non-KIO
#     apps. Not used: it would add a second session holder.
#   * go-mtpfs, android-file-transfer (aft-mtp-mount) — drop-in FUSE
#     alternates to simple-mtpfs; same flapping applies (it's the phone).
#   * programs.adb.enable — rock-solid `adb push/pull` on Xiaomi; add if
#     CLI transfers become the norm.
{ config, pkgs, lib, ... }:
let
  # Flap-tolerant gvfs MTP mounter. Mounts the first MTP volume via gio,
  # verifies with a real listing (a mount that raced the re-enumeration
  # comes up empty), retries with backoff, then points ~/mnt/phone at the
  # gvfs FUSE path (a stable name for a per-device directory).
  mtp-automount = pkgs.writeShellScriptBin "mtp-automount" ''
    set -u
    link="$1"                       # ~/mnt/phone
    gvfsdir="$XDG_RUNTIME_DIR/gvfs"
    tries=5
    settle=3   # phone re-enumerates ~1-6s after an aborted session

    # User services may predate a session with gvfs in GIO_EXTRA_MODULES;
    # point gio at the system gvfs modules explicitly so mounting works
    # regardless of when the user last logged in.
    export GIO_EXTRA_MODULES=/run/current-system/sw/lib/gio/modules
    gio=${pkgs.glib}/bin/gio
    timeout=${pkgs.coreutils}/bin/timeout

    # Already mounted (idempotent retrigger on re-plug/coldplug)?
    dir=$(ls -d "$gvfsdir"/mtp:host=* 2>/dev/null | head -n1 || true)
    if [ -n "$dir" ] && $timeout 8 ${pkgs.coreutils}/bin/ls "$dir" >/dev/null 2>&1; then
      echo "mtp-automount: already mounted at $dir"
    else
      i=0
      while [ "$i" -lt "$tries" ]; do
        i=$((i + 1))
        echo "mtp-automount: attempt $i/$tries"
        uri=$($gio mount -li 2>/dev/null | grep -o 'activation_root=mtp://[^ ]*' | head -n1 | cut -d= -f2)
        if [ -n "$uri" ] && $timeout 10 $gio mount "$uri"; then
          sleep 1
          dir=$(ls -d "$gvfsdir"/mtp:host=* 2>/dev/null | head -n1 || true)
          # Verify: a mount that raced the USB flap lists nothing.
          if [ -n "$dir" ] && $timeout 8 ${pkgs.coreutils}/bin/ls "$dir" >/dev/null 2>&1; then
            echo "mtp-automount: mounted $uri (attempt $i)"
            break
          fi
          echo "mtp-automount: mount came up empty — flap race, retrying"
        fi
        sleep "$settle"
      done
    fi

    [ -n "$dir" ] || { echo "mtp-automount: giving up after $tries attempts"; exit 1; }

    # Publish the stable path. If a previous run left a plain directory
    # (e.g. an old simple-mtpfs mountpoint), remove it first — ln -sfn
    # would silently nest inside it.
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      ${pkgs.coreutils}/bin/rmdir "$link" 2>/dev/null \
        || ${pkgs.coreutils}/bin/rm -rf "$link"
    fi
    mkdir -p "$(dirname "$link")"
    ${pkgs.coreutils}/bin/ln -sfn "$dir" "$link"
    echo "mtp-automount: $link -> $dir"
    exit 0
  '';
in
{
  # --- 1. MTP device tagging (any MTP-capable device) -----------------------
  services.udev.packages = [ pkgs.libmtp ];

  # --- 2. Trigger the user automount service when an MTP device appears ----
  # TAG+="systemd" gives the device a unit in the *user* manager too;
  # SYSTEMD_USER_WANTS then pulls in mtp-automount.service for the logged-in
  # user. extraRules land in 99-local.rules, safely after 69-libmtp.rules
  # has set ID_MTP_DEVICE on the same uevent.
  services.udev.extraRules = ''
    ACTION=="add|change", \
      SUBSYSTEM=="usb", \
      ENV{ID_MTP_DEVICE}=="1", \
      TAG+="systemd", \
      ENV{SYSTEMD_USER_WANTS}+="mtp-automount.service"
  '';

  # --- 3. The automount itself ----------------------------------------------
  # Type=oneshot WITHOUT RemainAfterExit: the unit goes inactive once gvfsd
  # holds the session, so the next plug-in can retrigger it and repoint the
  # symlink. gvfs auto-unmounts on unplug — no stale cleanup needed.
  systemd.user.services.mtp-automount = {
    description = "Auto-mount MTP (Android) device at ~/mnt/phone";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${mtp-automount}/bin/mtp-automount %h/mnt/phone";
      Restart = "on-failure";
      RestartSec = "5";
    };
  };

  # --- 4. Supporting packages -----------------------------------------------
  services.gvfs.enable = true;

  environment.systemPackages = with pkgs; [
    simple-mtpfs # DEBUGGING ONLY (--list-devices, reads): its WRITE path
                 # fails with EIO on the POCO X3 NFC — use ~/mnt/phone
  ];
}

