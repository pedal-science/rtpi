#!/usr/bin/env bash
# Restore a device to its known-good state. Run this when something has gone wrong and
# you want the board back to a boring, working kernel with no cleverness attached.
#
# This is deliberately blunt and deliberately does NOT need the candidate to be in any
# particular state.
#
# Usage: panic-button.sh piv [--reboot]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DEVICE="${1:?usage: panic-button.sh piv [--reboot]}"; shift || true
DO_REBOOT=0
[[ ${1:-} == --reboot ]] && DO_REBOOT=1

load_device "$DEVICE"
require_ssh

case "$DEVICE" in
  piv)
    log "current piboot state:"
    dev_ssh "sudo piboot-try --status 2>&1 || true"
    dev_ssh "for d in current new old; do
               printf '  %-8s ' \$d
               sudo cat $BOOT_MOUNT/\$d/state 2>/dev/null || echo '(absent)'
             done"

    # Mark any candidate bad so it can never be tried again unattended.
    if dev_ssh "test -d $BOOT_MOUNT/$CANDIDATE_SLOT"; then
      log "marking candidate bad so it is never auto-tried"
      dev_ssh "printf 'bad\n' | sudo tee $BOOT_MOUNT/$CANDIDATE_SLOT/state >/dev/null"
    fi

    # Drop the expectations so a later validate cannot fail on stale state.
    dev_ssh "sudo rm -f /etc/rtpi-expected-kernel /etc/rtpi-expect-realtime"

    # current/ is authoritative and must say good.
    dev_ssh "printf 'good\n' | sudo tee $BOOT_MOUNT/current/state >/dev/null"
    dev_ssh "sudo sync"
    ok "piv will boot current/ (known good) on the next reboot"
    ;;

  *) die "unknown device $DEVICE" ;;
esac

if (( DO_REBOOT )); then
  confirm "Reboot $SSH_HOST now?"
  dev_ssh "sudo systemctl reboot" || true
  log "rebooting; run:  scripts/safety/watch-reboot.sh $DEVICE"
fi
