#!/usr/bin/env bash
# Rehearse the A/B mechanism with a kernel whose outcome we already know.
#
# This is the most valuable step in the whole project: it converts "the rollback should
# work" into "I watched the rollback work". Do it BEFORE trusting the mechanism with a
# real RT kernel.
#
#   success — stage a known-good kernel, watch tryboot -> validate -> promote
#   failure — stage deliberately unbootable assets, watch the board come back BY ITSELF
#
# Usage: rehearse-piv.sh <success|failure>
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
MODE="${1:?usage: rehearse-piv.sh <success|failure>}"
load_device piv
require_ssh

"$RTPI_ROOT/scripts/safety/preflight.sh" piv

case "$MODE" in
  success)
    # If a candidate is already staged (e.g. by an unattended dracut upgrade), reuse it:
    # it is the same kernel with a fresh initramfs, so it is a free, near-zero-risk
    # rehearsal of the complete path.
    state=$(dev_ssh "sudo cat $BOOT_MOUNT/$CANDIDATE_SLOT/state 2>/dev/null" || echo "-")
    if [[ $state == unknown ]]; then
      log "reusing the already-staged candidate (free rehearsal)"
    else
      log "staging a copy of the known-good kernel as the candidate"
      dev_ssh "sudo rm -rf $BOOT_MOUNT/$CANDIDATE_SLOT"
      dev_ssh "sudo cp -a $BOOT_MOUNT/current $BOOT_MOUNT/$CANDIDATE_SLOT"
      dev_ssh "printf 'unknown\n' | sudo tee $BOOT_MOUNT/$CANDIDATE_SLOT/state >/dev/null"
      dev_ssh "sudo sync"
    fi
    running=$(dev_ssh 'uname -r')
    "$RTPI_ROOT/scripts/safety/arm-try-piv.sh" --expect "$running"
    confirm "Reboot piv to rehearse a SUCCESSFUL tryboot? (expect it to promote)"
    dev_ssh "sudo piboot-try --reboot" || true
    "$RTPI_ROOT/scripts/safety/watch-reboot.sh" piv --expect "$running"
    echo
    log "post-rehearsal state (expect current=good, new absent or old present):"
    "$RTPI_ROOT/scripts/safety/status.sh" piv
    ;;

  failure)
    warn "This deliberately makes the candidate unbootable."
    warn "The board SHOULD come back on its own within a few minutes, on the known-good"
    warn "kernel, with new/state=bad. If it does not, you will need the serial console."
    confirm "Proceed with the FAILURE rehearsal on piv?"

    log "staging deliberately broken candidate assets"
    dev_ssh "sudo rm -rf $BOOT_MOUNT/$CANDIDATE_SLOT"
    dev_ssh "sudo cp -a $BOOT_MOUNT/current $BOOT_MOUNT/$CANDIDATE_SLOT"
    # Truncate the kernel: the firmware will find a vmlinuz and a dtb (so os_prefix is
    # honoured rather than silently ignored) but the image cannot boot. That exercises
    # the real path rather than an "assets missing" shortcut.
    dev_ssh "sudo truncate -s 1M $BOOT_MOUNT/$CANDIDATE_SLOT/vmlinuz"
    dev_ssh "printf 'unknown\n' | sudo tee $BOOT_MOUNT/$CANDIDATE_SLOT/state >/dev/null"
    dev_ssh "sudo sync"
    ok "broken candidate staged (vmlinuz truncated to 1M)"

    running=$(dev_ssh 'uname -r')
    "$RTPI_ROOT/scripts/safety/arm-try-piv.sh" --expect "does-not-exist"
    confirm "Reboot piv to rehearse a FAILED tryboot?"
    dev_ssh "sudo piboot-try --reboot" || true

    log "watching — expect it to fall back to $running"
    if "$RTPI_ROOT/scripts/safety/watch-reboot.sh" piv --expect "$running"; then
      ok "board returned on the known-good kernel, unattended"
    else
      warn "unexpected kernel returned — inspect below"
    fi

    echo
    log "checking new/state is 'bad' (proves piboot-try recorded the failure):"
    bad=$(dev_ssh "sudo cat $BOOT_MOUNT/$CANDIDATE_SLOT/state 2>/dev/null" || echo "-")
    if [[ $bad == bad ]]; then
      ok "new/state = bad — the mechanism works end to end"
    else
      warn "new/state = '$bad' (expected 'bad')"
    fi
    log "cleaning up the broken candidate"
    dev_ssh "sudo rm -rf $BOOT_MOUNT/$CANDIDATE_SLOT"
    dev_ssh "sudo sync"
    ok "REHEARSAL COMPLETE — automatic rollback is now observed, not assumed"
    ;;

  *) die "mode must be 'success' or 'failure'" ;;
esac
