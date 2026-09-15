#!/usr/bin/env bash
# Arm a staged candidate kernel on piv for a one-shot tryboot.
#
# ORDERING IS LOAD-BEARING. flash-kernel's pi-try method does, verbatim:
#     cp "$boot_mnt"/current/cmdline.txt "$boot_mnt"/new/cmdline.txt
# so the candidate ALWAYS inherits the known-good kernel's cmdline. Our dracut safety
# arguments therefore have to be written into new/cmdline.txt AFTER flash-kernel has run
# and BEFORE the tryboot reboot. Do it the other way round and they are silently
# overwritten, and the most likely failure mode (root not found on the USB-SATA bridge)
# becomes an unrecoverable hang instead of an automatic rollback.
#
# We deliberately do NOT put these args in current/cmdline.txt: the known-good kernel
# should keep its normal, debuggable behaviour.
#
# Usage: arm-try-piv.sh --expect <kernel-release> [--realtime] [--reboot]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_device piv

EXPECT=""
REALTIME=0
DO_REBOOT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect)   EXPECT="$2"; shift 2 ;;
    --realtime) REALTIME=1; shift ;;
    --reboot)   DO_REBOOT=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n $EXPECT ]] || die "--expect <kernel-release> is required (so validation can check it)"

require_ssh
guard_stock_kernel_installed
guard_boot_space "$BOOT_MOUNT" "$BOOT_MIN_FREE_MB"

# There must actually be a candidate staged, in the untested state.
state=$(dev_ssh "sudo cat $BOOT_MOUNT/$CANDIDATE_SLOT/state 2>/dev/null" || echo "-")
case "$state" in
  unknown) ok "candidate present and untested (state=unknown)" ;;
  bad)     die "candidate is marked 'bad' from a previous failed attempt.
         Reset it first:  sudo piboot-try --reset-new" ;;
  trying)  die "candidate is mid-test (state=trying). Let it finish or reboot first." ;;
  good)    die "candidate is already validated — nothing to arm." ;;
  -)       die "no candidate staged in $BOOT_MOUNT/$CANDIDATE_SLOT. Install a kernel first." ;;
  *)       die "unexpected candidate state: '$state'" ;;
esac

# piboot-try's state key is "<tryboot>/<old>/<current>/<new>", and EVERY case that
# accepts a staged candidate is "[01]/-/good/unknown" — which requires old/ to be ABSENT.
# flash-kernel guarantees that by doing `rm -rf old new` before it stages. If old/ is
# present alongside an untested new/, the key becomes "X/good/good/unknown", no case
# matches, and piboot-try aborts with "invalid or unexpected state" and will NOT tryboot.
# Catch that here rather than discovering it at reboot time.
if dev_ssh "sudo test -d $BOOT_MOUNT/$ROLLBACK_SLOT"; then
  die "$ROLLBACK_SLOT/ exists alongside an untested $CANDIDATE_SLOT/.
         piboot-try cannot handle that combination and will refuse to tryboot.
         flash-kernel avoids it by removing $ROLLBACK_SLOT/ when it stages.
         Fix:  ssh $SSH_HOST sudo rm -rf $BOOT_MOUNT/$ROLLBACK_SLOT"
fi
ok "$ROLLBACK_SLOT/ absent — state key will be a form piboot-try accepts"

# Sanity: os_prefix is silently IGNORED unless BOTH the kernel and at least one .dtb
# exist under the prefix. A candidate missing either would boot the WRONG slot without
# any error, which would look like a pass.
dev_ssh "test -f $BOOT_MOUNT/$CANDIDATE_SLOT/vmlinuz" \
  || die "no vmlinuz in $CANDIDATE_SLOT — the firmware would silently ignore os_prefix"
dtb_count=$(dev_ssh "ls $BOOT_MOUNT/$CANDIDATE_SLOT/*.dtb 2>/dev/null | wc -l")
(( dtb_count > 0 )) \
  || die "no .dtb in $CANDIDATE_SLOT — the firmware would silently ignore os_prefix"
dev_ssh "test -f $BOOT_MOUNT/$CANDIDATE_SLOT/$BOARD_DTB" \
  || warn "$BOARD_DTB missing from candidate — this board needs it to boot"
ok "candidate has vmlinuz and $dtb_count dtb(s)"

# Write the candidate cmdline: inherited known-good args + our safety args.
log "writing safety args into $CANDIDATE_SLOT/cmdline.txt"
base=$(dev_ssh "sudo cat $BOOT_MOUNT/$CANDIDATE_SLOT/cmdline.txt")
# Strip any previously-added args so re-arming is idempotent.
cleaned=$(printf '%s' "$base" | tr ' ' '\n' \
  | grep -vE '^(rd\.shell|rd\.emergency|rd\.retry|rd\.timeout|panic)=' | tr '\n' ' ')
newcmdline="$(printf '%s %s %s' "${cleaned% }" "$DRACUT_SAFETY_ARGS" "$PANIC_ARGS")"
dev_ssh "printf '%s\n' \"$newcmdline\" | sudo tee $BOOT_MOUNT/$CANDIDATE_SLOT/cmdline.txt >/dev/null"
ok "candidate cmdline: $newcmdline"

# Tell the validate hook what to require.
dev_ssh "printf '%s\n' '$EXPECT' | sudo tee /etc/rtpi-expected-kernel >/dev/null"
if (( REALTIME )); then
  dev_ssh "sudo touch /etc/rtpi-expect-realtime"
  ok "validation will require PREEMPT_RT in uname -v"
else
  dev_ssh "sudo rm -f /etc/rtpi-expect-realtime"
fi
dev_ssh "printf '%s\n' '$AUDIO_USB_ID' | sudo tee /etc/rtpi-audio-usb-id >/dev/null"

dev_ssh "sudo sync"
ok "armed. Candidate will be tried on the next boot."

if (( DO_REBOOT )); then
  confirm "Reboot $SSH_HOST now to test the candidate?"
  log "triggering the tryboot via piboot-try (avoids the double-boot)"
  # Use piboot-try rather than hand-rolling `reboot "0 tryboot"`: it reads the boot
  # partition number from /proc/device-tree/chosen/bootloader/partition and passes
  # "<partition> tryboot", which is not always "0".
  dev_ssh "sudo piboot-try --reboot" || true
else
  log "not rebooting. To test now:   ssh $SSH_HOST sudo piboot-try --reboot"
  log "or just reboot normally and it will double-boot into the candidate."
fi
