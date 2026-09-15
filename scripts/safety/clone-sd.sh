#!/usr/bin/env bash
# Clone a device's boot SD card onto a spare, on the device itself.
#
# WHY A CLONE AND NOT A FRESH IMAGE
# A fresh Armbian image boots, but it is not a recovery: it has none of our setup, no
# frozen -good slot, no tooling, and it drops you back at the start of Phase 5. A raw
# clone of the working card is directly swappable -- power off, swap, power on, and the
# board is exactly where it was, including the bootloader at sector 64 and the U-Boot
# environment region at LBA 8128, both of which live outside any partition and which a
# file-level copy would miss.
#
# WHEN TO TAKE ONE
# Before risky changes, not after. A clone taken while the board is in a known-good state
# is a known-good recovery point; one taken after installing an untested boot script
# carries that untested boot script.
#
# CONSISTENCY
# The source is mounted read-write and live, so this is a crash-consistent copy, not an
# atomic one: the clone's ext4 journal will replay on its first boot. That is exactly what
# the journal is for and is how every SD-cloning guide works. We sync first and rely on
# /var/log being on zram (so logging does not touch the card). We deliberately do NOT
# fsfreeze or remount root read-only -- either can hang a live board for the duration of
# an 8GB copy, which is a worse risk than a journal replay.
#
# Full-device verification is NOT possible against a live source: the source keeps being
# written while we copy, so a whole-device hash would mismatch for entirely innocent
# reasons. Instead we verify the things that must be right and do not change: the
# bootloader region, the partition table, and the structural soundness of the copied
# filesystem.
#
# Usage: clone-sd.sh <piv|tib> --target /dev/sdX [--yes]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DEVICE="${1:?usage: clone-sd.sh <piv|tib> --target /dev/sdX}"; shift
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --yes)    RTPI_ASSUME_YES=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n $TARGET ]] || die "--target is required (e.g. --target /dev/sda)"

load_device "$DEVICE"
require_ssh

SOURCE="${UBOOT_ENV_DEV:-/dev/mmcblk0}"

# ---------------------------------------------------------------- refuse the obvious disasters
[[ $TARGET != "$SOURCE" ]] || die "target and source are the same device ($TARGET)"

log "checking $TARGET on $SSH_HOST"
dev_ssh "test -b $TARGET" || die "$TARGET is not a block device on $SSH_HOST"

# The single worst mistake this script could make is writing over the running system, so
# check it three ways rather than trusting the argument.
ROOT_SRC=$(dev_ssh "findmnt -no SOURCE /")
case "$ROOT_SRC" in
  "$TARGET"*) die "$TARGET holds the running root filesystem ($ROOT_SRC). Refusing." ;;
esac
MOUNTED=$(dev_ssh "lsblk -no MOUNTPOINT $TARGET 2>/dev/null | grep -v '^\$' || true")
[[ -z $MOUNTED ]] || die "$TARGET has mounted partitions:
$MOUNTED
         Unmount them first, or pick the right device."
IS_USB=$(dev_ssh "lsblk -dno TRAN $TARGET 2>/dev/null || true")
[[ $IS_USB == usb ]] || warn "$TARGET does not report TRAN=usb (got '${IS_USB:-none}') — is this really the card reader?"

SRC_SECTORS=$(dev_ssh "cat /sys/block/$(basename "$SOURCE")/size")
TGT_SECTORS=$(dev_ssh "cat /sys/block/$(basename "$TARGET")/size")
(( TGT_SECTORS >= SRC_SECTORS )) \
  || die "target is smaller than source ($TGT_SECTORS < $SRC_SECTORS sectors). A raw clone
         cannot work. Use a card at least as large as $SOURCE."

SRC_GB=$(awk "BEGIN{printf \"%.2f\", $SRC_SECTORS*512/1e9}")
TGT_GB=$(awk "BEGIN{printf \"%.2f\", $TGT_SECTORS*512/1e9}")

# ---------------------------------------------------------------- show what will be destroyed
log "TARGET CONTENTS (this will be destroyed):"
dev_ssh "sudo fdisk -l $TARGET 2>/dev/null | sed 's/^/    /'" || true
dev_ssh "sudo blkid ${TARGET}* 2>/dev/null | sed 's/^/    /'" || true

echo >&2
log "source : $SOURCE  ($SRC_GB GB)  — the card $SSH_HOST is running from"
log "target : $TARGET  ($TGT_GB GB)  — will be COMPLETELY OVERWRITTEN"
echo >&2

confirm "Overwrite $TARGET on $SSH_HOST with a clone of $SOURCE?"

# ---------------------------------------------------------------- the copy
log "quiescing writes and syncing"
dev_ssh "sync; sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true"

log "cloning $SRC_GB GB — expect several minutes; progress follows"
# conv=fsync so the copy is on the card before we verify it, not sitting in page cache.
dev_ssh "sudo dd if=$SOURCE of=$TARGET bs=4M conv=fsync status=progress" 2>&1 | sed 's/^/    /'

log "flushing"
dev_ssh "sync; sudo blockdev --flushbufs $TARGET 2>/dev/null || true"
dev_ssh "sudo partprobe $TARGET 2>/dev/null || true; sleep 2"

# ---------------------------------------------------------------- verify what must be right
log "verifying"

# 1. The bootloader region. Sectors 64..8192 carry the Rockchip idbloader and the U-Boot
#    environment, are never written during normal operation, and are the part a file-level
#    backup would silently miss. These MUST match exactly.
SRC_BOOT=$(dev_ssh "sudo dd if=$SOURCE bs=512 skip=64 count=8128 status=none | sha256sum | cut -d' ' -f1")
TGT_BOOT=$(dev_ssh "sudo dd if=$TARGET bs=512 skip=64 count=8128 status=none | sha256sum | cut -d' ' -f1")
if [[ $SRC_BOOT == "$TGT_BOOT" ]]; then
  ok "bootloader + env region matches ($SRC_BOOT)"
else
  die "BOOTLOADER REGION MISMATCH — the clone will not boot.
         source $SRC_BOOT
         target $TGT_BOOT"
fi

# 2. Partition table.
SRC_PT=$(dev_ssh "sudo dd if=$SOURCE bs=512 count=1 status=none | sha256sum | cut -d' ' -f1")
TGT_PT=$(dev_ssh "sudo dd if=$TARGET bs=512 count=1 status=none | sha256sum | cut -d' ' -f1")
[[ $SRC_PT == "$TGT_PT" ]] && ok "partition table matches" || warn "partition table differs — unexpected"

# 3. The copied filesystem must be structurally sound. -n means check only, change nothing.
#    Expect it to report the journal needing recovery: the source was live. That is normal
#    and is repaired automatically on first boot.
log "checking the cloned filesystem (read-only, no changes made)"
dev_ssh "sudo e2fsck -fn ${TARGET}1 2>&1 | tail -12 | sed 's/^/    /'" || \
  warn "e2fsck reported issues — see above. A dirty journal here is EXPECTED and harmless."

# 4. The files that make this a useful recovery card, rather than just a bootable one.
log "spot-checking contents of the clone"
dev_ssh "bash -s" <<REMOTE || warn "could not verify clone contents"
set -e
sudo mkdir -p /mnt/rtpi-clone
sudo mount -o ro ${TARGET}1 /mnt/rtpi-clone
for f in boot/zImage${GOOD_SLOT_SUFFIX} boot/uInitrd${GOOD_SLOT_SUFFIX} boot/boot.scr boot/armbianEnv.txt; do
  if [ -e "/mnt/rtpi-clone/\$f" ]; then echo "    present: \$f"; else echo "    MISSING: \$f"; fi
done
[ -d /mnt/rtpi-clone/boot/dtb${GOOD_SLOT_SUFFIX} ] && echo "    present: boot/dtb${GOOD_SLOT_SUFFIX}/" || echo "    MISSING: boot/dtb${GOOD_SLOT_SUFFIX}/"
sudo umount /mnt/rtpi-clone
sudo rmdir /mnt/rtpi-clone
REMOTE

echo >&2
ok "clone complete"
warn "IMPORTANT: the clone has the SAME filesystem UUID as the original"
warn "  ($(dev_ssh "sudo blkid -s UUID -o value ${SOURCE}p1 2>/dev/null || sudo blkid -s UUID -o value ${SOURCE}1"))"
warn "  and this board boots with root=UUID=. Leaving the clone plugged in during a boot"
warn "  can make the kernel mount the CLONE as root while U-Boot loaded the kernel from the"
warn "  SD. REMOVE THE CARD before any reboot or boot test."
