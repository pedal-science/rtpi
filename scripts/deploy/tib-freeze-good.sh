#!/usr/bin/env bash
# Freeze tib's currently-running kernel as the known-good fallback slot.
#
# Our custom boot.cmd DEFAULTS to this slot: every failure path, and every boot where
# rt_try is not 1, loads zImage-good / uInitrd-good / dtb-good. So these files are the
# thing that keeps the board reachable, and they must be a kernel we have SEEN boot.
#
# Deliberately real copies, not symlinks. Armbian's postinst rewrites the zImage/uInitrd/
# dtb symlinks to point at the newest installed kernel, and a kernel package removal can
# take the versioned directory with it. A symlink would silently follow; a copy is frozen.
#
# This is additive and invisible to the stock boot.scr, which never references *-good.
# Running it before installing our boot.scr is therefore zero-risk, and is the required
# order: the fallback must exist before anything can fall back to it.
#
# Usage: tib-freeze-good.sh [--force]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_device tib
require_ssh

FORCE=0
[[ ${1:-} == --force ]] && FORCE=1

RUNNING=$(dev_ssh 'uname -r')
log "running kernel on $SSH_HOST: $RUNNING"

# Refuse to freeze a kernel that is not the one we are currently talking to. Freezing an
# untested kernel as the fallback would defeat the entire point.
if [[ $RUNNING != "$STOCK_KERNEL" ]]; then
  warn "running kernel ($RUNNING) is not STOCK_KERNEL ($STOCK_KERNEL from device.env)"
  (( FORCE )) || die "refusing to freeze. Re-run with --force only if you are sure this
         kernel is known good, and update STOCK_KERNEL in devices/tib/device.env."
fi

# We are reaching the box over ssh on this kernel right now, which is the evidence that
# matters: it boots, it brings up the network, and sshd runs.
ok "this kernel is demonstrably good — we are connected to it over ssh"

if dev_ssh "test -e $BOOT_DIR/zImage$GOOD_SLOT_SUFFIX"; then
  EXISTING=$(dev_ssh "cat $BOOT_DIR/.rtpi-good-version 2>/dev/null" || echo "unknown")
  warn "a frozen slot already exists (kernel: $EXISTING)"
  (( FORCE )) || die "refusing to overwrite an existing fallback slot. Use --force if you
         really mean to replace it — but be certain the new one boots, because this is
         what the board falls back TO."
fi

guard_boot_space "/" 200

log "freezing $RUNNING into the ${GOOD_SLOT_SUFFIX} slot"

dev_ssh "bash -s" <<REMOTE
set -euo pipefail
cd "$BOOT_DIR"

# Resolve through the symlinks to the real files, so we copy content, not links.
KRN=\$(readlink -f zImage)
IRD=\$(readlink -f uInitrd)
DTB=\$(readlink -f dtb)

echo "  zImage  -> \$KRN"
echo "  uInitrd -> \$IRD"
echo "  dtb     -> \$DTB"

for f in "\$KRN" "\$IRD"; do
  [ -f "\$f" ] || { echo "missing: \$f" >&2; exit 1; }
done
[ -d "\$DTB" ] || { echo "not a directory: \$DTB" >&2; exit 1; }

# Write to .new first, then rename into place, so an interrupted copy can never leave a
# truncated fallback kernel behind.
sudo cp -f  "\$KRN" "zImage${GOOD_SLOT_SUFFIX}.new"
sudo cp -f  "\$IRD" "uInitrd${GOOD_SLOT_SUFFIX}.new"
sudo rm -rf "dtb${GOOD_SLOT_SUFFIX}.new"
sudo cp -a  "\$DTB" "dtb${GOOD_SLOT_SUFFIX}.new"
sync

sudo rm -rf "dtb${GOOD_SLOT_SUFFIX}"
sudo mv -f "zImage${GOOD_SLOT_SUFFIX}.new"  "zImage${GOOD_SLOT_SUFFIX}"
sudo mv -f "uInitrd${GOOD_SLOT_SUFFIX}.new" "uInitrd${GOOD_SLOT_SUFFIX}"
sudo mv -T "dtb${GOOD_SLOT_SUFFIX}.new"     "dtb${GOOD_SLOT_SUFFIX}"
sync

# Verify byte-for-byte. A fallback slot we have not verified is not a fallback slot.
cmp -s "\$KRN" "zImage${GOOD_SLOT_SUFFIX}" || { echo "zImage copy MISMATCH" >&2; exit 1; }
cmp -s "\$IRD" "uInitrd${GOOD_SLOT_SUFFIX}" || { echo "uInitrd copy MISMATCH" >&2; exit 1; }

# The dtb our board actually boots must be present in the frozen directory, or U-Boot's
# load of \${rtpi_dtb}/\${fdtfile} fails and region 2 falls through to a dead slot.
[ -f "dtb${GOOD_SLOT_SUFFIX}/$BOARD_DTB" ] || {
  echo "frozen dtb dir is missing $BOARD_DTB" >&2; exit 1; }

echo "$RUNNING" | sudo tee .rtpi-good-version >/dev/null
sync

echo
echo "frozen slot:"
ls -la "zImage${GOOD_SLOT_SUFFIX}" "uInitrd${GOOD_SLOT_SUFFIX}"
ls -d  "dtb${GOOD_SLOT_SUFFIX}"
echo "  contains $BOARD_DTB: yes"
REMOTE

ok "frozen $RUNNING as the known-good slot"
log "the stock boot.scr does not reference these files, so nothing about this boot changed."
log "next: install boot.scr, then reboot once to bootstrap the U-Boot environment."
