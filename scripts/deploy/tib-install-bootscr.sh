#!/usr/bin/env bash
# Install the rtpi one-shot boot script on tib.
#
# This is the step that turns the frozen -good slot from inert files into an actual
# fallback. Until it runs, tib has NO automatic recovery: the stock boot.scr boots
# whatever the zImage/uInitrd/dtb symlinks point at, and Armbian's postinst repoints
# those at the newest installed kernel.
#
# THE FIRST BOOT AFTER THIS IS THE RISKY ONE. With rt_try unset, the new script boots the
# -good slot, which is a copy of the kernel currently running -- so a correct script boots
# exactly what is booting today. A broken script means no boot at all, recoverable only at
# the board: power off, swap or re-image the card.
#
# Every precondition that could cause a silent no-boot is checked before anything is
# written, because the cost of finding out afterwards is a trip to the hardware.
#
# Usage: tib-install-bootscr.sh [--yes]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_device tib
require_ssh
[[ ${1:-} == --yes ]] && RTPI_ASSUME_YES=1

SRC="$RTPI_ROOT/devices/tib/boot/boot.cmd"
[[ -f $SRC ]] || die "missing $SRC"

log "preflight"

dev_ssh 'command -v mkimage >/dev/null' || die "mkimage not on $SSH_HOST (install u-boot-tools)"
ok "mkimage present"

# fdtfile is NOT in armbianEnv.txt on this board; U-Boot supplies it from its built-in
# environment as a FLAT name (fdtfile=rk3288-tinker-s.dtb), not a vendor-prefixed path.
# Resolve it the same way the boot script will, rather than assuming.
FDT=$(dev_ssh "grep -oP '(?<=^fdtfile=).*' $BOOT_ENV_FILE 2>/dev/null" || true)
[[ -n $FDT ]] || FDT="$BOARD_DTB"
log "fdtfile resolves to: $FDT"

# The fallback slot must be complete, or the default boot path -- the one every failure
# lands on -- is dead.
log "checking the known-good slot is complete"
dev_ssh "bash -s" <<REMOTE || die "known-good slot is incomplete — refusing to install"
set -e
fail=0
for f in "$BOOT_DIR/zImage$GOOD_SLOT_SUFFIX" "$BOOT_DIR/uInitrd$GOOD_SLOT_SUFFIX" "$BOOT_DIR/dtb$GOOD_SLOT_SUFFIX/$FDT"; do
  if [ -e "\$f" ]; then echo "    OK      \$f"; else echo "    MISSING \$f"; fail=1; fi
done
OVL=\$(grep -oP '(?<=^overlays=).*' "$BOOT_ENV_FILE" 2>/dev/null || true)
PFX=\$(grep -oP '(?<=^overlay_prefix=).*' "$BOOT_ENV_FILE" 2>/dev/null || echo rockchip)
for o in \$OVL; do
  f="$BOOT_DIR/dtb$GOOD_SLOT_SUFFIX/overlay/\$PFX-\$o.dtbo"
  if [ -e "\$f" ]; then echo "    OK      \$f"; else echo "    MISSING \$f"; fail=1; fi
done
exit \$fail
REMOTE
ok "known-good slot is complete, including its own overlays"

# Belt and braces: the running kernel should be the one we froze, so the slot we are about
# to make the default is a kernel we have actually seen boot.
RUNNING=$(dev_ssh 'uname -r')
FROZEN=$(dev_ssh "cat $BOOT_DIR/.rtpi-good-version 2>/dev/null" || echo "")
[[ $RUNNING == "$FROZEN" ]] \
  || warn "running kernel ($RUNNING) != frozen slot ($FROZEN) — the fallback is not the kernel you are talking to"
[[ $RUNNING == "$FROZEN" ]] && ok "fallback slot is the running kernel ($RUNNING)"

echo >&2
log "this will replace $BOOT_SCRIPT_SRC and $BOOT_SCRIPT_BIN"
log "next boot will use the '$GOOD_SLOT_SUFFIX' slot and bootstrap the U-Boot environment"
confirm "Install the one-shot boot script on $SSH_HOST?"

# Keep the stock pair on the device. It does not help if the board will not boot -- you
# would be reading the card elsewhere anyway -- but it makes an ssh-reachable mistake a
# one-line fix.
log "backing up the stock boot script on-device"
dev_ssh "sudo cp -n $BOOT_SCRIPT_SRC $BOOT_SCRIPT_SRC.stock 2>/dev/null || true
         sudo cp -n $BOOT_SCRIPT_BIN $BOOT_SCRIPT_BIN.stock 2>/dev/null || true
         ls -la $BOOT_SCRIPT_SRC.stock $BOOT_SCRIPT_BIN.stock" | sed 's/^/    /' >&2

log "installing boot.cmd"
scp "${SSH_OPTS[@]}" -q "$SRC" "$SSH_HOST:/tmp/rtpi-boot.cmd"
dev_ssh "sudo install -m 0644 -o root -g root /tmp/rtpi-boot.cmd $BOOT_SCRIPT_SRC && rm -f /tmp/rtpi-boot.cmd"

log "compiling boot.scr"
dev_ssh "sudo mkimage -C none -A arm -T script -d $BOOT_SCRIPT_SRC $BOOT_SCRIPT_BIN" | sed 's/^/    /' >&2

log "verifying the compiled script"
# grep -a, not strings: tib has no binutils, and grep handles the binary fine.
dev_ssh "sudo grep -a -q rtpi $BOOT_SCRIPT_BIN" \
  || die "compiled $BOOT_SCRIPT_BIN does not contain our script — restore with:
         sudo cp $BOOT_SCRIPT_BIN.stock $BOOT_SCRIPT_BIN"
ok "boot.scr contains the rtpi script"

dev_ssh "sudo sync"
ok "installed"

echo >&2
log "NEXT BOOT will:"
log "  1. find rt_try unset, run saveenv, and bootstrap the U-Boot environment"
log "  2. boot the '$GOOD_SLOT_SUFFIX' slot — a copy of $RUNNING, the kernel running now"
log "Nothing else changes. Reboot when ready:"
log "    ssh $SSH_HOST 'sudo reboot' && ./scripts/safety/watch-reboot.sh tib"
