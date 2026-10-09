#!/usr/bin/env bash
# Back up a device's boot assets AND pull a copy to the Mac.
#
# Pulling the copy off the device is the whole point: a backup that only exists on a
# board you can no longer reach is not a backup. On piv this matters more than usual
# right now, because unattended-upgrades destroyed the old/ rollback slot on 2026-09-15
# (any package that regenerates the initramfs re-runs flash-kernel, which does
# `rm -rf old new` when old/ exists).
#
# Usage: backup-boot.sh piv

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DEVICE="${1:?usage: backup-boot.sh piv}"
load_device "$DEVICE"
require_ssh

STAMP="$(timestamp)"
LOCAL_DIR="$RTPI_ROOT/devices/$DEVICE/backups/$STAMP"
mkdir -p "$LOCAL_DIR"

log "backing up boot assets on $SSH_HOST"

case "$DEVICE" in
  piv)
    REMOTE_TAR="/var/tmp/rtpi-boot-$STAMP.tar"
    # Exclude nothing: we want an exact restorable image of the boot partition.
    dev_ssh "sudo tar -C '$BOOT_MOUNT' -cf '$REMOTE_TAR' . 2>/dev/null; sudo chmod 0644 '$REMOTE_TAR'"
    log "pulling to $LOCAL_DIR"
    scp "${SSH_OPTS[@]}" -q "$SSH_HOST:$REMOTE_TAR" "$LOCAL_DIR/boot-firmware.tar"
    dev_ssh "sudo rm -f '$REMOTE_TAR'"

    # Small text artefacts committed to git for quick diffing and recovery reference.
    dev_ssh "sudo cat $BOOT_MOUNT/config.txt"            > "$LOCAL_DIR/config.txt"
    dev_ssh "sudo cat $BOOT_MOUNT/autoboot.txt"          > "$LOCAL_DIR/autoboot.txt"
    dev_ssh "sudo cat $BOOT_MOUNT/current/cmdline.txt"   > "$LOCAL_DIR/current-cmdline.txt"
    dev_ssh "sudo cat $BOOT_MOUNT/current/state"         > "$LOCAL_DIR/current-state.txt" || true
    dev_ssh "sudo piboot-try --status 2>&1 || true"      > "$LOCAL_DIR/piboot-status.txt"
    dev_ssh "dpkg -l | grep -E '^ii  linux-(image|modules)'" > "$LOCAL_DIR/installed-kernels.txt" || true
    ;;

  *) die "unknown device $DEVICE" ;;
esac

ln -sfn "$STAMP" "$RTPI_ROOT/devices/$DEVICE/backups/latest"
ok "backup complete: $LOCAL_DIR"
ls -la "$LOCAL_DIR" >&2
