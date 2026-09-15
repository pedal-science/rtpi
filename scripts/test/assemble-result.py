#!/usr/bin/env python3
"""Turn a raw run directory into one result JSON matching results/README.md.

Kept separate from run-suite.sh so a run that completed on the device is never lost to a
formatting bug here: the raw cyclictest JSON stays in results/raw/ and this can be re-run.

The percentiles come from cyclictest's own histogram when present. Note that cyclictest
reports per-thread numbers; for an audio workload the interesting figure is the WORST
thread, because the audio callback can be scheduled on any core, so that is what we keep.
"""

import argparse
import json
import os
import sys


def read_facts(path):
    facts = {}
    if not os.path.exists(path):
        return facts
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if "=" in line:
            k, v = line.split("=", 1)
            facts[k] = v
    return facts


def percentiles(hist, wanted):
    """Percentiles from a pooled {latency_us: count} histogram.

    Pooled across threads on purpose: an audio callback can be scheduled on any core, so
    the distribution that matters is of ALL wakeups, not of one core's.

    cyclictest buckets at 1us and puts anything at or beyond the histogram width into an
    overflow counter, which carries no latency value. Overflow samples are still counted
    in the total so a percentile cannot be understated, but a percentile that falls inside
    the overflow region is reported as None rather than guessed at -- max_us is the honest
    number there.
    """
    total = sum(hist.values())
    if total == 0:
        return {}
    out = {}
    for pct in wanted:
        target = total * pct / 100.0
        seen = 0
        val = None
        for latency in sorted(hist):
            seen += hist[latency]
            if seen >= target:
                val = latency
                break
        out[pct] = val
    return out


def read_histfile(path):
    """Parse a cyclictest --histfile into a pooled {latency_us: count} plus overflows.

    Format is one line per microsecond bucket: the latency, then one count per thread.
    Trailer lines start with '#'. Threads are pooled deliberately -- an audio callback can
    land on any core, so the distribution that matters is of all wakeups.
    """
    pooled, overflows = {}, 0
    if not os.path.exists(path):
        return pooled, overflows
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            if "Histogram Overflows:" in line:
                for tok in line.split(":", 1)[1].split():
                    try:
                        overflows += int(tok)
                    except ValueError:
                        pass
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            latency = int(parts[0])
            count = sum(int(x) for x in parts[1:])
        except ValueError:
            continue
        if count:
            pooled[latency] = pooled.get(latency, 0) + count
    return pooled, overflows


def percentiles(hist, wanted):
    """Percentiles from a pooled {latency_us: count} histogram."""
    total = sum(hist.values())
    if total == 0:
        return {}
    out = {}
    for pct in wanted:
        target = total * pct / 100.0
        seen = 0
        val = None
        for latency in sorted(hist):
            seen += hist[latency]
            if seen >= target:
                val = latency
                break
        out[pct] = val
    return out


def summarise(ct, histpath):
    """Worst-case across threads from the JSON, percentiles from the histogram."""
    threads = ct.get("thread", {})
    if not threads:
        return None

    def worst(key):
        vals = [int(t[key]) for t in threads.values() if key in t]
        return max(vals) if vals else None

    out = {
        "min_us": min((int(t["min"]) for t in threads.values() if "min" in t), default=None),
        "avg_us": worst("avg"),          # worst thread's average, not the mean of means
        "max_us": worst("max"),
    }

    pooled, overflows = read_histfile(histpath)
    out["samples"] = sum(pooled.values()) + overflows
    out["histogram_overflows"] = overflows

    if pooled:
        # Fold overflow in at the top so high percentiles cannot be understated. A
        # percentile that lands in that synthetic bucket has no real value to report --
        # max_us is the honest number there -- so it is recorded as null, not guessed.
        width = max(pooled) + 1
        adj = dict(pooled)
        if overflows:
            adj[width] = adj.get(width, 0) + overflows
        p = percentiles(adj, [50, 99, 99.9, 99.99])
        for pct, key in ((50, "p50_us"), (99, "p99_us"),
                         (99.9, "p99_9_us"), (99.99, "p99_99_us")):
            v = p.get(pct)
            out[key] = None if (v is not None and overflows and v >= width) else v

    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", required=True)
    ap.add_argument("--stamp", required=True)
    ap.add_argument("--raw-dir", required=True)
    ap.add_argument("--duration", type=int, required=True)
    ap.add_argument("--load", required=True)
    ap.add_argument("--label", default="")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    facts = read_facts(os.path.join(a.raw_dir, "facts.txt"))

    result = {
        "board": a.device,
        "kernel": facts.get("kernel_release", "unknown"),
        "kernel_version": facts.get("kernel_version", ""),
        "realtime": facts.get("realtime") == "true",
        "config_hash": facts.get("config_hash", ""),
        "timestamp": a.stamp,
        "label": a.label,
        "tunables": {
            "governor": facts.get("governor", "unknown"),
            "scaling_max_khz": facts.get("scaling_max_khz", "unknown"),
            "cpuinfo_max_khz": facts.get("cpuinfo_max_khz", "unknown"),
            "rt_runtime_us": facts.get("rt_runtime_us", "unknown"),
            "rt_period_us": facts.get("rt_period_us", "unknown"),
            "watchdog": facts.get("watchdog", "unknown"),
            "nproc": facts.get("nproc", "unknown"),
            "hz": facts.get("cfg_CONFIG_HZ", "unknown"),
            "no_hz_full": facts.get("cfg_CONFIG_NO_HZ_FULL", "n"),
            "rcu_boost": facts.get("cfg_CONFIG_RCU_BOOST", "n"),
            "rt_group_sched": facts.get("cfg_CONFIG_RT_GROUP_SCHED", "n"),
            # False means SCHED_FIFO is denied outside the root cgroup, so no ordinary
            # audio application can get a realtime priority on this kernel at all.
            "sched_fifo_in_cgroup": facts.get("sched_fifo_in_cgroup", "unknown"),
        },
        "load": a.load,
        "audio_cards": facts.get("audio_cards", ""),
        "cyclictest": {},
    }

    found = False
    for name in sorted(os.listdir(a.raw_dir)):
        if not name.startswith("cyclictest-") or not name.endswith(".json"):
            continue
        frames = name[len("cyclictest-"):-len(".json")]
        path = os.path.join(a.raw_dir, name)
        if os.path.getsize(path) == 0:
            continue
        try:
            ct = json.load(open(path, encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as e:
            print(f"  warning: could not parse {name}: {e}", file=sys.stderr)
            continue
        s = summarise(ct, os.path.join(a.raw_dir, f"cyclictest-{frames}.hist"))
        if s is None:
            continue
        s["interval_us"] = int(frames) * 1000000 // 48000
        s["duration_s"] = a.duration
        s["period_frames"] = int(frames)
        result["cyclictest"][frames] = s
        found = True

    if not found:
        print("no usable cyclictest data — refusing to write an empty result",
              file=sys.stderr)
        return 1

    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, sort_keys=True)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
