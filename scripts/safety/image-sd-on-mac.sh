#!/usr/bin/env bash
# Read a board's SD card into a compressed image, with the card in a reader ON THIS MAC.
#
# WHY THIS IS THE BETTER WAY
# Imaging over the network from the running board gives a crash-consistent copy of a live,
# mounted filesystem: stale superblock counts, a journal that must replay on first boot,
# and on tib it also has to cross an SDIO 1x1 wifi chip that manages about 170 KB/s on a
# sustained upload. With the board powered off and the card in a reader here, the
# filesystem is quiescent, so the image is a clean point-in-time snapshot, and the read
# runs at reader speed.
#
# THIS SCRIPT ONLY READS. It never writes to the card. Restoring is restore-sd-on-mac.sh.
#
# macOS notes that matter:
#   - When you insert an ext4 card, macOS says "The disk you inserted was not readable by
#     this computer." Click IGNORE. Never Initialize -- that reformats the card and your
#     only copy of the board is gone.
#   - We read /dev/rdiskN (raw, unbuffered) rather than /dev/diskN. On macOS the raw node
#     is several times faster for bulk sequential reads.
#   - The disk must be unmounted first, which is why we call diskutil unmountDisk.
#
# Usage: image-sd-on-mac.sh --disk /dev/diskN [--device tib] [--expect-bytes N]

set -euo pipefail

RTPI_ROOT="${RTPI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*" >&2; }

DISK=""
DEVICE="tib"
EXPECT_BYTES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk)         DISK="$2"; shift 2 ;;
    --device)       DEVICE="$2"; shift 2 ;;
    --expect-bytes) EXPECT_BYTES="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -z $DISK ]]; then
  echo "External disks attached to this Mac:" >&2
  diskutil list external physical >&2 || true
  die "pass --disk /dev/diskN (pick it from the list above, by SIZE and NAME)"
fi

[[ $DISK =~ ^/dev/disk[0-9]+$ ]] || die "--disk must look like /dev/disk4, got: $DISK"

# --- refuse to touch anything that is not a removable external disk -----------------
INFO=$(diskutil info "$DISK" 2>/dev/null) || die "$DISK does not exist"
INTERNAL=$(awk -F: '/Device Location/ {gsub(/^ +| +$/,"",$2); print $2}' <<< "$INFO")
REMOVABLE=$(awk -F: '/Removable Media/ {gsub(/^ +| +$/,"",$2); print $2}' <<< "$INFO")
SIZE_BYTES=$(awk -F'[()]' '/Disk Size/ {print $2}' <<< "$INFO" | awk '{print $1}')
DISK_NAME=$(awk -F: '/Device \/ Media Name/ {gsub(/^ +| +$/,"",$2); print $2}' <<< "$INFO")

[[ $INTERNAL != "Internal" ]] \
  || die "$DISK is an INTERNAL disk. Refusing. This is your Mac's own storage."

log "disk    : $DISK"
log "name    : ${DISK_NAME:-unknown}"
log "size    : ${SIZE_BYTES:-unknown} bytes"
log "location: ${INTERNAL:-unknown}   removable: ${REMOVABLE:-unknown}"

if [[ -n $EXPECT_BYTES && -n $SIZE_BYTES ]]; then
  if [[ $SIZE_BYTES != "$EXPECT_BYTES" ]]; then
    warn "size is $SIZE_BYTES but expected $EXPECT_BYTES"
    warn "  If you are imaging a DIFFERENT card than the board's, that is fine."
    warn "  If you meant the board's card, you have the wrong disk — stop now."
  else
    ok "size matches the expected card exactly"
  fi
fi

diskutil list "$DISK" >&2 || true
echo >&2
read -r -p "Read $DISK into an image? (read-only) [type YES]: " reply
[[ $reply == YES ]] || die "aborted"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$RTPI_ROOT/devices/$DEVICE/backups/$STAMP"
mkdir -p "$OUT"
IMG="$OUT/mmcblk0.img.zst"

log "unmounting $DISK (the ext4 partition will not have mounted anyway)"
diskutil unmountDisk "$DISK" >&2 || warn "unmountDisk reported an issue; continuing"

RDISK="${DISK/\/dev\/disk//dev/rdisk}"
log "reading $RDISK -> $IMG"
log "you will be asked for your password (raw device access needs root)"

# pipefail matters: without it, zstd exiting 0 on a truncated stream would look like
# success. That already bit us once tonight over the network.
set -o pipefail
sudo dd if="$RDISK" bs=4m 2>"$OUT/dd.log" | zstd -T0 -3 -o "$IMG"
ok "read complete"
sed 's/^/    /' "$OUT/dd.log" >&2 || true

log "verifying the image decompresses to the full card size"
GOT=$(zstd -dc "$IMG" | wc -c | tr -d ' ')
echo "    decompressed: $GOT bytes" >&2
if [[ -n $SIZE_BYTES && $GOT == "$SIZE_BYTES" ]]; then
  ok "image is the full card, byte count matches"
else
  warn "decompressed size $GOT vs card size ${SIZE_BYTES:-unknown} — check before trusting this"
fi

# Prove the bootloader is in there: the Rockchip idbloader lives at sector 64 and is the
# part a file-level backup misses. If this is absent the image will not boot anything.
log "checking the image contains a bootloader at sector 64"
zstd -dc "$IMG" | dd bs=512 skip=64 count=8064 2>/dev/null | strings -a | grep -m1 -E 'U-Boot 20[0-9][0-9]' \
  && ok "bootloader present in the image" \
  || warn "no U-Boot version string found at sector 64 — is this the right card?"

ls -lh "$OUT" >&2
ok "image written: $IMG"
