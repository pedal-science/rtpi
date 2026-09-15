#!/usr/bin/env bash
# Write a card image back to an SD card in a reader ON THIS MAC. DESTRUCTIVE.
#
# This is how you make a new recovery card, or resurrect a board whose card has died.
# Because the image is card-independent, recovery no longer depends on one specific card
# being compatible with the RK3288 BootROM -- which is what bit us on 2026-09-15, when a
# byte-perfect clone on a 32GB card would not boot at all.
#
# UNLIKE THE LIVE-SOURCE CASE, FULL VERIFICATION IS POSSIBLE HERE. Nothing is mounted and
# nothing is being written during the check, so after writing we read the card back and
# compare it byte-for-byte against the image. That is a complete proof the bytes landed,
# not a proxy for one.
#
# WHAT IT STILL CANNOT PROVE: that the BootROM will accept the card. Only a power-on can.
# Boot-test every recovery card before you rely on it, and prefer the same make and model
# as the card the board already boots from.
#
# Usage: restore-sd-on-mac.sh --disk /dev/diskN --image path/to/mmcblk0.img.zst

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*" >&2; }

DISK=""; IMAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk)  DISK="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -z $DISK || -z $IMAGE ]]; then
  echo "External disks attached to this Mac:" >&2
  diskutil list external physical >&2 || true
  die "usage: restore-sd-on-mac.sh --disk /dev/diskN --image <file.img.zst>"
fi
[[ -f $IMAGE ]] || die "no such image: $IMAGE"
[[ $DISK =~ ^/dev/disk[0-9]+$ ]] || die "--disk must look like /dev/disk4, got: $DISK"

INFO=$(diskutil info "$DISK" 2>/dev/null) || die "$DISK does not exist"
INTERNAL=$(awk -F: '/Device Location/ {gsub(/^ +| +$/,"",$2); print $2}' <<< "$INFO")
SIZE_BYTES=$(awk -F'[()]' '/Disk Size/ {print $2}' <<< "$INFO" | awk '{print $1}')
DISK_NAME=$(awk -F: '/Device \/ Media Name/ {gsub(/^ +| +$/,"",$2); print $2}' <<< "$INFO")

# The one mistake that cannot be undone is writing to the wrong disk, so check hard.
[[ $INTERNAL != "Internal" ]] \
  || die "$DISK is an INTERNAL disk. Refusing — this is your Mac's own storage."

BOOT_DISK=$(diskutil info / 2>/dev/null | awk -F: '/Part of Whole/ {gsub(/ /,"",$2); print $2}')
[[ "$DISK" != "/dev/$BOOT_DISK" ]] \
  || die "$DISK is the disk this Mac booted from. Refusing."

log "measuring image (decompressing to count bytes)"
set +o pipefail
IMG_BYTES=$(zstd -dc "$IMAGE" 2>/dev/null | wc -c | tr -d ' ')
set -o pipefail
[[ -n $IMG_BYTES && $IMG_BYTES -gt 0 ]] || die "image appears empty: $IMAGE"

log "image  : $IMAGE"
log "         $IMG_BYTES bytes uncompressed"
log "target : $DISK  (${DISK_NAME:-unknown})"
log "         ${SIZE_BYTES:-unknown} bytes"

if [[ -n $SIZE_BYTES ]]; then
  (( SIZE_BYTES >= IMG_BYTES )) \
    || die "target is smaller than the image ($SIZE_BYTES < $IMG_BYTES). It cannot hold it."
  (( SIZE_BYTES == IMG_BYTES )) \
    || warn "target is larger than the image; the extra $(( (SIZE_BYTES - IMG_BYTES) / 1024 / 1024 ))MB will be left unused (harmless)"
fi

echo >&2
diskutil list "$DISK" >&2 || true
echo >&2
warn "EVERYTHING ON $DISK WILL BE DESTROYED."
read -r -p "Type the disk identifier to confirm (e.g. disk4): " reply
[[ "/dev/$reply" == "$DISK" ]] || die "aborted — you typed '$reply'"

log "unmounting $DISK"
diskutil unmountDisk "$DISK" >&2 || warn "unmountDisk reported an issue; continuing"

RDISK="${DISK/\/dev\/disk//dev/rdisk}"
log "writing — this needs your password"
zstd -dc "$IMAGE" | sudo dd of="$RDISK" bs=4m
sync
ok "write complete"

# --- full verification, possible because nothing here is live ------------------------
log "verifying: reading the card back and comparing against the image"
IMG_HASH=$(zstd -dc "$IMAGE" | shasum -a 256 | cut -d' ' -f1)
CARD_HASH=$(sudo dd if="$RDISK" bs=4m count=$(( (IMG_BYTES + 4194303) / 4194304 )) 2>/dev/null \
            | head -c "$IMG_BYTES" | shasum -a 256 | cut -d' ' -f1)
echo "    image: $IMG_HASH" >&2
echo "    card : $CARD_HASH" >&2
if [[ $IMG_HASH == "$CARD_HASH" ]]; then
  ok "card matches the image byte-for-byte"
else
  die "MISMATCH — the card did not take the image correctly. Do not rely on it.
         A card that fails this is failing, counterfeit, or the reader is faulty."
fi

diskutil eject "$DISK" >&2 2>/dev/null || true
echo >&2
ok "done"
warn "THIS DOES NOT PROVE THE CARD BOOTS."
warn "  The bytes are provably correct, but the RK3288 BootROM rejects some cards that"
warn "  Linux reads perfectly — that is exactly how the 32GB clone failed. Boot-test this"
warn "  card now, while the working one is still to hand."
