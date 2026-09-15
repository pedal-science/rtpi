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
#     --max-freq KHZ   cap CPU frequency, restored afterwards (e.g. 1416000)
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
MAXFREQ=""
WITH_LOAD=1
LABEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --periods)  PERIODS="$2";  shift 2 ;;
    --governor) GOVERNOR="$2"; shift 2 ;;
    --max-freq) MAXFREQ="$2"; shift 2 ;;
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
echo "scaling_max_khz=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || echo unknown)"
echo "cpuinfo_max_khz=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq 2>/dev/null || echo unknown)"
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
# Thermal state, because on 2026-09-15 this board hit its 90C critical trip mid-suite and
# the kernel did a HARDWARE PROTECTION shutdown. It idles at 67C with passive throttling
# trips at 70C and 75C, so a sustained run crosses both early and measures a THROTTLED
# machine. A latency number recorded without the temperature that produced it is not
# comparable to one recorded at a different temperature.
for z in /sys/class/thermal/thermal_zone*; do
  [ -e "$z" ] || continue
  echo "thermal_$(cat $z/type 2>/dev/null)_start_mC=$(cat $z/temp 2>/dev/null)"
done
for t in /sys/class/thermal/thermal_zone0/trip_point_*_temp; do
  [ -e "$t" ] || continue
  n=$(basename "$t" | sed 's/_temp//')
  echo "trip_${n}_$(cat /sys/class/thermal/thermal_zone0/${n}_type 2>/dev/null)_mC=$(cat $t)"
done
REMOTE
sed 's/^/    /' "$RAW_DIR/facts.txt" >&2

KERNEL=$(grep '^kernel_release=' "$RAW_DIR/facts.txt" | cut -d= -f2-)
ORIG_GOV=$(grep '^governor=' "$RAW_DIR/facts.txt" | cut -d= -f2-)

# ---------------------------------------------------------------- governor
ORIG_MAXFREQ=$(dev_ssh "cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null" || echo "")

restore_tunables() {
  if [[ -n $GOVERNOR && -n $ORIG_GOV && $ORIG_GOV != unknown ]]; then
    log "restoring governor to $ORIG_GOV"
    dev_ssh "echo $ORIG_GOV | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null" || true
  fi
  if [[ -n $MAXFREQ && -n $ORIG_MAXFREQ ]]; then
    log "restoring max frequency to $ORIG_MAXFREQ"
    dev_ssh "echo $ORIG_MAXFREQ | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq >/dev/null" || true
  fi
}
if [[ -n $GOVERNOR || -n $MAXFREQ ]]; then
  trap restore_tunables EXIT
fi

# Frequency cap FIRST, so that switching to the performance governor -- which immediately
# runs at scaling_max_freq -- cannot briefly slam the board to 1.8GHz.
#
# This exists because this board cannot sustain its top bin: on 2026-09-15 a 15-minute
# suite drove it into the 90C critical trip and the kernel shut the board down mid-run. It
# idles in the 60s with passive trips at 70C and 75C, so an uncapped run does not measure a
# 1.8GHz machine -- it measures whatever the thermal governor leaves after throttling, and
# a different amount of it on every run. A cap the board can actually hold is both
# survivable AND reproducible, which matters more for comparison than a high number.
if [[ -n $MAXFREQ ]]; then
  log "capping CPU frequency at $(( MAXFREQ / 1000 ))MHz (was $(( ${ORIG_MAXFREQ:-0} / 1000 ))MHz)"
  dev_ssh "echo $MAXFREQ | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq >/dev/null" \
    || die "could not set scaling_max_freq"
  ACTUAL=$(dev_ssh "cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")
  [[ $ACTUAL == "$MAXFREQ" ]] || warn "requested $MAXFREQ but got $ACTUAL (not an available operating point?)"
  ok "max frequency now $(( ACTUAL / 1000 ))MHz"
fi

if [[ -n $GOVERNOR ]]; then
  log "setting governor to $GOVERNOR (was $ORIG_GOV)"
  dev_ssh "echo $GOVERNOR | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null" \
    || die "could not set governor"
fi

# Re-read the tunables AFTER changing them, and overwrite what was captured before.
# The facts block runs first, so without this the result records the state the board was
# in when we arrived rather than the state it was measured in -- a run made at
# performance/1416MHz would be filed as ondemand/1800MHz. Recording the wrong tunables is
# worse than recording none, because the numbers look comparable and are not.
if [[ -n $GOVERNOR || -n $MAXFREQ ]]; then
  NEW_GOV=$(dev_ssh "cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null" || echo unknown)
  NEW_CAP=$(dev_ssh "cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null" || echo unknown)
  sed -i.bak -e "s|^governor=.*|governor=$NEW_GOV|" \
             -e "s|^scaling_max_khz=.*|scaling_max_khz=$NEW_CAP|" "$RAW_DIR/facts.txt"
  rm -f "$RAW_DIR/facts.txt.bak"
  ok "recording tunables actually in force: governor=$NEW_GOV cap=$(( NEW_CAP / 1000 ))MHz"
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

# Sample thermals for the duration, self-terminating so a dropped connection cannot
# leave it running.
( end=\$(( \$(date +%s) + $DURATION + 20 ))
  peak=0; minfreq=99999999
  while [ \$(date +%s) -lt \$end ]; do
    t=\$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
    f=\$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    [ "\$t" -gt "\$peak" ] 2>/dev/null && peak=\$t
    [ "\$f" -gt 0 ] && [ "\$f" -lt "\$minfreq" ] 2>/dev/null && minfreq=\$f
    echo "peak_mC=\$peak min_khz=\$minfreq last_mC=\$t last_khz=\$f" > /tmp/rtpi-therm-$FRAMES
    sleep 5
  done ) &

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

  # Peak temperature and minimum CPU frequency seen during the run. Throttling is the
  # thing that silently invalidates a comparison, so record it rather than hoping.
  dev_ssh "cat /tmp/rtpi-therm-${FRAMES} 2>/dev/null" > "$RAW_DIR/thermal-${FRAMES}.txt" || true
  dev_ssh "sudo rm -f /tmp/rtpi-therm-${FRAMES}" || true

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
