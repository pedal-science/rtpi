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

  pro)
    # x86/UEFI: there is no boot partition to image the way piv's is. What decides what pro boots
    # is grub.cfg, grubenv, /etc/default/grub[.d], the pedal's state under /var/lib/rtpi, and the
    # firmware's own boot order — so those are what is copied, and they are small enough to commit
    # and to diff.
    # Every one of these runs under `bash -s`, not the host's login shell: pro's is zsh, which
    # ABORTS on a glob that matches nothing instead of passing the pattern through. The first
    # version of this script died exactly there, on /var/lib/rtpi/pro-boot/* before pro-boot was
    # installed, and took the rest of the backup with it.
    dev_ssh "sudo -n cat /boot/grub/grub.cfg"                  > "$LOCAL_DIR/grub.cfg"
    dev_ssh "sudo -n grub-editenv $GRUBENV list"               > "$LOCAL_DIR/grubenv.txt" || true
    dev_ssh "cat /etc/default/grub"                            > "$LOCAL_DIR/default-grub.txt"
    dev_ssh "cat /proc/cmdline"                                > "$LOCAL_DIR/current-cmdline.txt"
    dev_ssh "sudo -n efibootmgr -v 2>/dev/null || echo 'efibootmgr not installed'" \
                                                               > "$LOCAL_DIR/efibootmgr.txt"
    dev_ssh "mokutil --sb-state 2>&1 || true"                  > "$LOCAL_DIR/secureboot.txt"
    dev_ssh "sudo -n pro-boot status 2>&1 || echo 'pro-boot is not installed yet'" \
                                                               > "$LOCAL_DIR/pro-boot-status.txt"

    dev_ssh 'bash -s' > "$LOCAL_DIR/default-grub.d.txt" <<'EOF' || true
shopt -s nullglob
for f in /etc/default/grub.d/*; do echo "== $f"; cat "$f"; done
EOF

    dev_ssh 'bash -s' > "$LOCAL_DIR/pro-boot-state.txt" <<'EOF' || true
shopt -s nullglob
found=0
for f in /var/lib/rtpi/pro-boot/*; do echo "== $f"; cat "$f"; found=1; done
(( found )) || echo "no pro-boot state yet"
EOF

    dev_ssh 'bash -s' > "$LOCAL_DIR/installed-kernels.txt" <<'EOF' || true
dpkg -l | grep -E '^ii  (linux-(image|modules)|grub|shim)' || true
echo "== holds"; apt-mark showhold || true
echo "== /boot"; ls -la /boot
echo "== ESP"; ls -la /boot/efi/EFI/ubuntu 2>/dev/null || true
EOF

    # The BIOS settings that affect latency, through HP's own firmware-attributes interface. This is
    # pro's answer to vip's eeprom.lock: a record of the firmware's state, read and never written.
    # Worth having in git because a BIOS reset, or somebody pressing F10, is otherwise invisible.
    dev_ssh 'bash -s' > "$LOCAL_DIR/bios-settings.txt" <<'EOF' || true
shopt -s nullglob
for a in /sys/class/firmware-attributes/hp-bioscfg/attributes/*/; do
  v=$(cat "$a/current_value" 2>/dev/null) || continue
  [[ -n $v ]] && printf '%s=%s\n' "$(basename "$a")" "$v"
done | sort
EOF
    ;;

  *) die "unknown device $DEVICE" ;;
esac

ln -sfn "$STAMP" "$RTPI_ROOT/devices/$DEVICE/backups/latest"
ok "backup complete: $LOCAL_DIR"
ls -la "$LOCAL_DIR" >&2
