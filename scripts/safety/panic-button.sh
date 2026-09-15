#!/usr/bin/env bash
# Restore a device to its known-good state. Run this when something has gone wrong and
# you want the board back to a boring, working kernel with no cleverness attached.
#
# This is deliberately blunt and deliberately does NOT need the candidate to be in any
# particular state.
#
# Usage: panic-button.sh <piv|tib> [--reboot]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DEVICE="${1:?usage: panic-button.sh <piv|tib> [--reboot]}"; shift || true
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

  tib)
    # Disarm the one-shot. If the env is not yet initialised there is nothing to clear,
    # and that is fine — an uninitialised env means the flag was never set.
    if dev_ssh "command -v fw_printenv >/dev/null 2>&1"; then
      if dev_ssh "sudo fw_printenv $TRY_VAR >/dev/null 2>&1"; then
        log "clearing $TRY_VAR"
        dev_ssh "sudo fw_setenv $TRY_VAR 0"
      else
        log "$TRY_VAR not set — nothing to clear"
      fi
    else
      warn "fw_printenv not installed; cannot clear $TRY_VAR from Linux"
    fi

    # Point the live symlinks back at the frozen known-good slot.
    log "restoring known-good kernel symlinks"
    dev_ssh "set -e
      cd $BOOT_DIR
      for f in zImage uInitrd; do
        if [ -e \"\$f$GOOD_SLOT_SUFFIX\" ]; then
          sudo ln -sfn \"\$(basename \"\$f$GOOD_SLOT_SUFFIX\")\" \"\$f\"
          echo \"  \$f -> \$f$GOOD_SLOT_SUFFIX\"
        fi
      done
      sudo sync" || warn "no frozen -good slot found; leaving symlinks alone"
    ok "tib will boot the known-good kernel on the next reboot"
    ;;
esac

if (( DO_REBOOT )); then
  confirm "Reboot $SSH_HOST now?"
  dev_ssh "sudo systemctl reboot" || true
  log "rebooting; run:  scripts/safety/watch-reboot.sh $DEVICE"
fi
