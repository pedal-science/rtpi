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
MODE="${1:?usage: rehearse-piv.sh <success|failure|failure-hard>}"
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
      # See the note in the failure branch: old/ must be absent or piboot-try refuses.
      dev_ssh "sudo rm -rf $BOOT_MOUNT/$ROLLBACK_SLOT $BOOT_MOUNT/$CANDIDATE_SLOT"
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

  failure|failure-hard)
    # Two ways to break a candidate. They test different layers.
    #
    #   failure       (default) — a VALID kernel with a bogus root=. The kernel boots,
    #                  dracut cannot find root, and our rd.timeout/rd.emergency=reboot
    #                  arguments should reboot the board automatically. This is both the
    #                  realistic RT failure on piv (root is on a USB-SATA bridge, so a
    #                  kernel that mis-handles xHCI lands exactly here) AND the only way
    #                  to prove the dracut arguments actually work. Expect recovery in
    #                  roughly 2-4 minutes with no human involvement.
    #
    #   failure-hard  — a truncated kernel image. The firmware cannot load it at all, so
    #                  this fails BEFORE any kernel, watchdog or dracut exists. Recovery
    #                  is a power cycle (after which tryboot, being one-shot and already
    #                  consumed, boots the known-good slot). Only useful if you
    #                  specifically want to exercise the firmware-level path.
    warn "This deliberately breaks the candidate kernel."
    if [[ $MODE == failure-hard ]]; then
      warn "Mode: failure-hard — the firmware will be unable to load the kernel."
      warn "This will almost certainly need a PHYSICAL POWER CYCLE to recover."
    else
      warn "Mode: failure — the kernel will boot but be unable to find its root filesystem."
      warn "It SHOULD reboot itself within a few minutes and come back on the known-good"
      warn "kernel. If it does not, power-cycle it: tryboot is one-shot and already spent,"
      warn "so a cold boot lands on current/."
    fi
    confirm "Proceed with the $MODE rehearsal on piv?"

    log "staging a copy of the known-good kernel as the candidate"
    # Mirror flash-kernel exactly: it does `rm -rf old new` before staging. That is not
    # merely tidying — EVERY state-machine case that accepts a staged candidate is
    # "[01]/-/good/unknown", which requires old/ to be ABSENT. Leaving old/ in place
    # produces "1/good/good/unknown", which no case matches, and piboot-try bails with
    # "piboot is in an invalid or unexpected state" and refuses to tryboot.
    dev_ssh "sudo rm -rf $BOOT_MOUNT/$ROLLBACK_SLOT $BOOT_MOUNT/$CANDIDATE_SLOT"
    dev_ssh "sudo cp -a $BOOT_MOUNT/current $BOOT_MOUNT/$CANDIDATE_SLOT"
    dev_ssh "printf 'unknown\n' | sudo tee $BOOT_MOUNT/$CANDIDATE_SLOT/state >/dev/null"
    dev_ssh "sudo sync"

    running=$(dev_ssh 'uname -r')

    # Arm FIRST: arm-try-piv.sh rewrites new/cmdline.txt (because flash-kernel copies
    # current/cmdline.txt over it verbatim). Only after that can we inject the breakage,
    # or it would be overwritten.
    "$RTPI_ROOT/scripts/safety/arm-try-piv.sh" --expect "$running"

    if [[ $MODE == failure-hard ]]; then
      log "truncating the candidate kernel to 1M"
      # Truncate rather than delete: os_prefix is silently IGNORED unless both a kernel
      # and a .dtb exist under it, so deleting would test the wrong path entirely and
      # "pass" for the wrong reason.
      dev_ssh "sudo truncate -s 1M $BOOT_MOUNT/$CANDIDATE_SLOT/vmlinuz"
      ok "candidate kernel truncated"
    else
      log "pointing the candidate's root= at a device that does not exist"
      dev_ssh "sudo sed -i 's|root=LABEL=writable|root=LABEL=rtpi-no-such-fs|' \
                 $BOOT_MOUNT/$CANDIDATE_SLOT/cmdline.txt"
      ok "candidate cmdline now: $(dev_ssh "sudo cat $BOOT_MOUNT/$CANDIDATE_SLOT/cmdline.txt")"
      dev_ssh "sudo grep -q 'rd.emergency=reboot' $BOOT_MOUNT/$CANDIDATE_SLOT/cmdline.txt" \
        || die "the dracut safety args are missing — aborting, this would hang forever"
      ok "dracut safety args confirmed present (this is what we are testing)"
    fi
    dev_ssh "sudo sync"

    confirm "Reboot piv to run the $MODE rehearsal?"
    dev_ssh "sudo piboot-try --reboot" || true

    log "watching — expect it to fall back to $running by itself"
    rc=0
    "$RTPI_ROOT/scripts/safety/watch-reboot.sh" piv --expect "$running" --timeout 900 || rc=$?

    echo
    if (( rc == 0 )); then
      ok "board returned on the known-good kernel, UNATTENDED"
    else
      warn "board did not return as expected (rc=$rc). If it is still down, power-cycle it;"
      warn "tryboot is one-shot and already consumed, so a cold boot loads current/."
      die "rehearsal did not complete — investigate before trusting the mechanism"
    fi

    log "checking new/state is 'bad' (proves piboot-try recorded the failure):"
    bad=$(dev_ssh "sudo cat $BOOT_MOUNT/$CANDIDATE_SLOT/state 2>/dev/null" || echo "-")
    if [[ $bad == bad ]]; then
      ok "new/state = bad — the mechanism works end to end"
    else
      warn "new/state = '$bad' (expected 'bad') — worth understanding why"
    fi

    log "cleaning up"
    dev_ssh "sudo rm -rf $BOOT_MOUNT/$CANDIDATE_SLOT"
    # Clear the expectations too, or a later validate would fail against stale state.
    dev_ssh "sudo rm -f /etc/rtpi-expected-kernel /etc/rtpi-expect-realtime"
    dev_ssh "sudo sync"
    ok "REHEARSAL COMPLETE — automatic rollback is now observed, not assumed"
    ;;

  *) die "mode must be 'success', 'failure' or 'failure-hard'" ;;
esac
