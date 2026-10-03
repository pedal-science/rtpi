#!/usr/bin/env bash
# Watch a device through a reboot and report which kernel came back.
#
# This is the instrument that makes every risky boot observable. It must handle the
# DOUBLE REBOOT that piboot-try performs on piv: the first boot sees new/state=unknown,
# writes "trying", and immediately reboots again into tryboot. So the device goes
# away -> comes back -> goes away -> comes back. A naive "wait for it to return" would
# declare success after the first bounce, before the candidate kernel has even run.
#
# Usage: watch-reboot.sh <piv|tib> [--expect <kernel-release>] [--timeout <sec>]
#
# Exit 0 = came back running the expected kernel (or any kernel, if --expect omitted)
# Exit 1 = came back on a DIFFERENT kernel (i.e. it fell back — the candidate failed)
# Exit 2 = never came back within the timeout

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DEVICE="${1:?usage: watch-reboot.sh <piv|tib> [--expect REL] [--timeout SEC]}"; shift
EXPECT=""
TIMEOUT=600
SETTLE=90          # how long the device must stay up before we believe it is settled

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect)  EXPECT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --settle)  SETTLE="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_device "$DEVICE"

# Probe EVERY known address, not just the primary. After a risky boot the interface we
# normally use may be the one that broke -- which is exactly the case this tool exists to
# detect. Reporting "never came back" when the board is up and reachable on its other
# address would be the worst possible failure mode for this script.
# probe echoes "<path> <kernel>" rather than setting a variable: it is called as
# $(probe), which runs in a subshell, so any assignment inside it is discarded in the
# parent. That is why the first version reported "answered on " with an empty path.
LAST_PATH=""
probe() {
  local h out
  while IFS= read -r h; do
    [[ -n $h ]] || continue
    out=$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=4 "$h" 'uname -r' 2>/dev/null) || continue
    [[ -n $out ]] || continue
    printf '%s %s' "$h" "$out"
    return 0
  done < <(ssh_hosts)
  return 1
}

start=$(date +%s)
elapsed() { echo $(( $(date +%s) - start )); }

log "watching $SSH_HOST (timeout ${TIMEOUT}s, settle ${SETTLE}s)"
log "paths: $(ssh_hosts | tr '\n' ' ')"
[[ -n $EXPECT ]] && log "expecting kernel: $EXPECT"

# Phase 1: wait for it to go away. If it never does, the reboot was not triggered.
log "waiting for $SSH_HOST to go down..."
while probe >/dev/null 2>&1; do
  (( $(elapsed) < 120 )) || die "device never went down — was the reboot actually armed?"
  sleep 2
done
ok "device went down after $(elapsed)s"

# Phase 2: wait for it to come back and STAY back. Any bounce inside the settle window
# means we caught the intermediate tryboot reboot, so we reset and keep waiting.
last_seen=""
stable_since=0
while (( $(elapsed) < TIMEOUT )); do
  if probe_out=$(probe) && [[ -n $probe_out ]]; then
    LAST_PATH="${probe_out%% *}"
    kernel="${probe_out#* }"
    now=$(date +%s)
    if [[ $kernel != "$last_seen" ]]; then
      log "up, running: $kernel (t+$(elapsed)s) — answered on $LAST_PATH"
      last_seen="$kernel"
      stable_since=$now
    elif (( now - stable_since >= SETTLE )); then
      ok "settled on $kernel after $(elapsed)s (reachable on $LAST_PATH)"
      # Which paths came back matters as much as which kernel did: a candidate that boots
      # but loses an interface is a partial failure worth seeing, not a clean pass.
      for h in $(ssh_hosts); do
        if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=4 "$h" true >/dev/null 2>&1; then
          ok "  path up:   $h"
        else
          warn "  path DOWN: $h"
        fi
      done
      if [[ -z $EXPECT ]]; then
        echo "$kernel"; exit 0
      elif [[ $kernel == "$EXPECT" ]]; then
        # Deliberately says only what is known. The kernel matching --expect does NOT by
        # itself mean the candidate booted: while a freshly frozen fallback holds the same
        # kernel version as the candidate, both slots report identical uname output. On tib
        # the slot is readable from /proc/cmdline, so report that instead of inferring.
        ok "kernel matches --expect"
        # piv/tib mark the slot rtpi.slot=…; vip marks it vipboot.slot=… (rtpi's vip-boot).
        SLOT=$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=6 "${LAST_PATH:-$SSH_HOST}" \
               "grep -oE '(rtpi|vipboot)\.slot=[a-z-]*' /proc/cmdline 2>/dev/null" || true)
        if [[ -n $SLOT ]]; then
          ok "booted slot: ${SLOT#*.slot=}"
        else
          warn "no slot marker on the kernel cmdline — cannot tell which slot booted"
        fi
        echo "$kernel"; exit 0
      else
        warn "came back on '$kernel', NOT the expected '$EXPECT'"
        warn "the candidate failed and the board fell back — this is the safety net working"
        echo "$kernel"; exit 1
      fi
    fi
  else
    # Went away again: that is the second leg of piboot-try's double reboot.
    if [[ -n $last_seen ]]; then
      log "went down again (expected once, for the tryboot leg)"
      last_seen=""
    fi
  fi
  sleep 3
done

die "device did not come back within ${TIMEOUT}s — see README 'Recovery'"
