#!/usr/bin/env bash
# Run the latency suite on a device and record one JSON file per run.
#
# WHAT THIS MEASURES AND WHY
# The number that matters for audio is the MAXIMUM, not the mean. One late wakeup is one
# audible xrun; an excellent average with a 2ms outlier is a broken audio system. So every
# run records max and high percentiles, and the comparison script ranks on max.
#
# cyclictest is run at the actual 48 kHz audio period intervals rather than a round number,
# because that is the wakeup pattern a real audio callback produces:
#     64 frames -> 1333us    128 -> 2667us    256 -> 5333us
#
# SAFETY
# Everything gets a hard timeout, on the device, in the device's own shell. If this Mac
# loses the ssh connection mid-run, the load generators still die on their own rather than
# leaving a board pinned at 100% on every core indefinitely.
#
# That matters more than usual here because systemd's watchdog is armed (30s on tib, 14s on
# piv). A board starved hard enough that systemd cannot pet the watchdog will REBOOT. That
# is by design and it is recoverable, but it will end your run, so use --no-load or a
# shorter duration if you see unexplained reboots.
#
# Usage:
#   run-suite.sh <piv|tib> [options]
#     --duration N     seconds per period          (default 300)
#     --periods "..."  frame counts at 48kHz       (default "64 128 256")
#     --governor G     set governor for the run, restored afterwards
#     --no-load        measure idle instead of under load
#     --label TEXT     free-text note stored in the result

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DEVICE="${1:?usage: run-suite.sh <piv|tib> [options]}"; shift || true
load_device "$DEVICE"
require_ssh

DURATION=300
PERIODS="64 128 256"
GOVERNOR=""
WITH_LOAD=1
LABEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --periods)  PERIODS="$2";  shift 2 ;;
    --governor) GOVERNOR="$2"; shift 2 ;;
    --no-load)  WITH_LOAD=0;   shift ;;
    --label)    LABEL="$2";    shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

dev_ssh 'command -v cyclictest >/dev/null' \
  || die "cyclictest not installed on $SSH_HOST. Install rt-tests."
if (( WITH_LOAD )); then
  dev_ssh 'command -v stress-ng >/dev/null' \
    || die "stress-ng not installed on $SSH_HOST (needed unless --no-load)."
fi

STAMP="$(timestamp)"
OUT_DIR="$RTPI_ROOT/results"
mkdir -p "$OUT_DIR"
RAW_DIR="$OUT_DIR/raw/$DEVICE-$STAMP"
mkdir -p "$RAW_DIR"

# ---------------------------------------------------------------- system facts
# Captured at run time, not assumed. A latency number without the tunables that produced
# it is not comparable to anything.
log "capturing system state"
dev_ssh 'bash -s' > "$RAW_DIR/facts.txt" <<'REMOTE'
set -u
echo "kernel_release=$(uname -r)"
echo "kernel_version=$(uname -v)"
if uname -v | grep -q PREEMPT_RT; then echo "realtime=true"; else echo "realtime=false"; fi
echo "nproc=$(nproc)"
echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
echo "rt_runtime_us=$(cat /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null || echo unknown)"
echo "rt_period_us=$(cat /proc/sys/kernel/sched_rt_period_us 2>/dev/null || echo unknown)"
echo "watchdog=$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null || echo unknown)"
cfg=/boot/config-$(uname -r)
if [ -r "$cfg" ]; then
  echo "config_hash=sha256:$(sha256sum "$cfg" | cut -d' ' -f1)"
  for s in CONFIG_HZ CONFIG_PREEMPT_RT CONFIG_NO_HZ_FULL CONFIG_RCU_BOOST CONFIG_RT_GROUP_SCHED; do
    v=$(grep -E "^$s=" "$cfg" | head -1 | cut -d= -f2)
    [ -n "$v" ] || v="n"
    echo "cfg_$s=$v"
  done
elif [ -r /proc/config.gz ]; then
  echo "config_hash=sha256:$(zcat /proc/config.gz | sha256sum | cut -d' ' -f1)"
fi
echo "audio_cards=$(tr '\n' '|' < /proc/asound/cards 2>/dev/null | sed 's/  */ /g')"
# Can an ordinary service/session get SCHED_FIFO here? With RT_GROUP_SCHED=y on cgroup v2
# the answer is no, which is a property of the kernel worth recording next to the numbers.
if chrt -f 50 true 2>/dev/null; then echo "sched_fifo_in_cgroup=true"; else echo "sched_fifo_in_cgroup=false"; fi
echo "uptime_s=$(cut -d' ' -f1 /proc/uptime)"
REMOTE
sed 's/^/    /' "$RAW_DIR/facts.txt" >&2

KERNEL=$(grep '^kernel_release=' "$RAW_DIR/facts.txt" | cut -d= -f2-)
ORIG_GOV=$(grep '^governor=' "$RAW_DIR/facts.txt" | cut -d= -f2-)

# ---------------------------------------------------------------- governor
restore_governor() {
  [[ -n $GOVERNOR && -n $ORIG_GOV && $ORIG_GOV != unknown ]] || return 0
  log "restoring governor to $ORIG_GOV"
  dev_ssh "echo $ORIG_GOV | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null" || true
}
if [[ -n $GOVERNOR ]]; then
  log "setting governor to $GOVERNOR (was $ORIG_GOV)"
  dev_ssh "echo $GOVERNOR | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null" \
    || die "could not set governor"
  trap restore_governor EXIT
fi

# ---------------------------------------------------------------- the runs
NPROC=$(grep '^nproc=' "$RAW_DIR/facts.txt" | cut -d= -f2-)
LOAD_DESC="idle"
(( WITH_LOAD )) && LOAD_DESC="stress-ng --cpu $NPROC --io 2 --vm 1 --vm-bytes 128M + hackbench"

log "kernel $KERNEL | load: $LOAD_DESC | ${DURATION}s per period"
warn "total run time is about $(( $(wc -w <<< "$PERIODS") * DURATION / 60 )) minutes"

for FRAMES in $PERIODS; do
  INTERVAL=$(( FRAMES * 1000000 / 48000 ))
  log "period ${FRAMES} frames = ${INTERVAL}us, ${DURATION}s"

  # Hard cap every remote command. GRACE covers cyclictest's own startup and teardown.
  GRACE=$(( DURATION + 60 ))

  # cyclictest writes the JSON and the histogram to two different places, and with
  # --json=/dev/stdout the histogram dump lands on stdout right after the JSON object,
  # producing a file that is not valid JSON. So send each to its own file on the device
  # and fetch them separately.
  RJSON="/tmp/rtpi-ct-${FRAMES}.json"
  RHIST="/tmp/rtpi-ct-${FRAMES}.hist"

  dev_ssh "bash -s" >/dev/null <<REMOTE || warn "run for ${FRAMES} frames failed"
set -u
cleanup() { pkill -f 'stress-ng' 2>/dev/null || true; pkill -f hackbench 2>/dev/null || true; }
trap cleanup EXIT

sudo rm -f "$RJSON" "$RHIST"

if [ "$WITH_LOAD" = "1" ]; then
  # --timeout makes the load self-terminating even if this shell dies.
  stress-ng --cpu $NPROC --io 2 --vm 1 --vm-bytes 128M \\
            --timeout $(( DURATION + 15 ))s --quiet >/dev/null 2>&1 &
  # hackbench in a loop generates scheduler wakeup storms, which is the thing that
  # actually hurts RT latency; stress-ng alone is mostly steady-state CPU burn.
  ( end=\$(( \$(date +%s) + $DURATION + 10 ))
    while [ \$(date +%s) -lt \$end ]; do hackbench -l 200 >/dev/null 2>&1 || break; done ) &
  sleep 3   # let the load reach steady state before measuring
fi

# Two things are load-bearing in this invocation.
#
# 1. --histogram/--histfile gives the percentile data; without it cyclictest reports only
#    min/avg/max. 1000 one-microsecond buckets is far wider than any acceptable audio
#    latency, so anything landing in overflow is already a failure -- and max still
#    records its true value regardless.
#
# 2. The root-cgroup move. This kernel has CONFIG_RT_GROUP_SCHED=y and runs cgroup v2 with
#    the cpu controller enabled, which denies SCHED_FIFO to any task outside the root
#    cgroup -- EVEN AS ROOT. Verified on tib: 'sudo chrt -f 50 true' fails with EPERM in a
#    session scope and succeeds after moving to /sys/fs/cgroup/cgroup.procs. Without this,
#    cyclictest exits immediately with "Unable to change scheduling policy!".
#
#    Note what that implies beyond this script: on such a kernel JACK and every other
#    SCHED_FIFO audio application is refused too. RT_GROUP_SCHED=n in our own config is
#    not a nicety.
#
#    \$\$ is escaped so the INNER shell expands it to its own pid, not this one.
sudo bash -c 'echo \$\$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
exec timeout -s INT ${GRACE}s cyclictest \\
    --mlockall --priority=99 --threads=$NPROC --affinity \\
    --interval=$INTERVAL --duration=${DURATION} \\
    --histogram=1000 --histfile=$RHIST \\
    --quiet --json=$RJSON' >/dev/null 2>&1

sudo chmod 0644 "$RJSON" "$RHIST" 2>/dev/null || true
cleanup
REMOTE

  dev_ssh "cat $RJSON 2>/dev/null" > "$RAW_DIR/cyclictest-${FRAMES}.json" || true
  dev_ssh "cat $RHIST 2>/dev/null" > "$RAW_DIR/cyclictest-${FRAMES}.hist" || true
  dev_ssh "sudo rm -f $RJSON $RHIST" || true

  if [[ -s "$RAW_DIR/cyclictest-${FRAMES}.json" ]]; then
    ok "period ${FRAMES}: $(python3 -c "
import json,sys
d=json.load(open('$RAW_DIR/cyclictest-${FRAMES}.json'))
t=d.get('thread',{})
mx=max(int(v['max']) for v in t.values()) if t else -1
av=max(int(v['avg']) for v in t.values()) if t else -1
print(f'max={mx}us  worst-thread-avg={av}us')" 2>/dev/null || echo "recorded")"
  else
    warn "period ${FRAMES}: no data"
  fi
done

# ---------------------------------------------------------------- assemble result
RESULT="$OUT_DIR/$DEVICE-$KERNEL-$STAMP.json"
python3 "$RTPI_ROOT/scripts/test/assemble-result.py" \
  --device "$DEVICE" --stamp "$STAMP" --raw-dir "$RAW_DIR" \
  --duration "$DURATION" --load "$LOAD_DESC" --label "$LABEL" \
  --out "$RESULT"

ok "wrote $RESULT"
