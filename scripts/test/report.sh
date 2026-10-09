#!/usr/bin/env bash
# Render a comparison across recorded runs.
#
# Ranks on MAXIMUM latency, not mean. One late wakeup is one audible xrun, so an excellent
# average with a bad outlier is a broken audio system. The mean is not reported at all.
#
# Every row carries the tunables that produced it -- governor, clock cap, HZ, peak
# temperature -- because a latency figure without them is not comparable to anything.
#
# Usage: report.sh [--board <name>]      (e.g. --board piv)

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BOARD=""
[[ ${1:-} == --board ]] && BOARD="$2"

python3 - "$RTPI_ROOT" "$BOARD" <<'PY'
import json, os, sys, glob

root, board = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
files = sorted(glob.glob(os.path.join(root, "results", "*.json")))
runs = []
for f in files:
    try:
        d = json.load(open(f))
    except (json.JSONDecodeError, OSError):
        continue
    if board and d.get("board") != board:
        continue
    if not d.get("cyclictest"):
        continue
    d["_file"] = os.path.basename(f)
    runs.append(d)

if not runs:
    print("no results recorded yet")
    sys.exit(0)

def peak_temp(d, frames):
    raw = os.path.join(root, "results", "raw")
    for p in glob.glob(os.path.join(raw, "%s-%s" % (d["board"], d["timestamp"]), "thermal-%s.txt" % frames)):
        txt = open(p).read()
        out = {}
        for tok in txt.split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                out[k] = v
        if "peak_mC" in out:
            mhz = int(out.get("min_khz", 0) or 0) // 1000
            return "%dC/%dMHz" % (int(out["peak_mC"]) // 1000, mhz)
    return "-"

print()
for d in runs:
    t = d["tunables"]
    cap = t.get("scaling_max_khz", "unknown")
    cap = "%dMHz" % (int(cap) // 1000) if str(cap).isdigit() else cap
    print("%s  %s" % (d["board"], d["kernel"]))
    print("  realtime=%-5s HZ=%-5s governor=%-12s cap=%-8s rt_group_sched=%s sched_fifo_in_cgroup=%s"
          % (d["realtime"], t.get("hz"), t.get("governor"), cap,
             t.get("rt_group_sched"), t.get("sched_fifo_in_cgroup", "?")))
    if d.get("label"):
        print("  %s" % d["label"])
    print("    %-7s %-9s %-8s %-8s %-9s %-9s %-9s %s"
          % ("frames", "period", "p50", "p99", "p99.9", "MAX", "%budget", "peak/minclk"))
    for k in sorted(d["cyclictest"], key=int):
        c = d["cyclictest"][k]
        def s(v): return "-" if v is None else "%sus" % v
        pct = 100.0 * c["max_us"] / c["interval_us"]
        print("    %-7s %-9s %-8s %-8s %-9s %-9s %-9.1f %s"
              % (k, "%dus" % c["interval_us"], s(c.get("p50_us")), s(c.get("p99_us")),
                 s(c.get("p99_9_us")), s(c["max_us"]), pct, peak_temp(d, k)))
    print()

# ---------------------------------------------------------------- tuning head-to-head
# Same board, same KERNEL, differing only in CPU isolation. This is the comparison piv
# needs and the RT-vs-non-RT one below cannot express: on piv the kernel never changes,
# only the command line does, so keying on kernel release finds nothing to compare.
#
# Ranked on p99.9 rather than max. Max is a single rare event -- across these runs one
# 182us outlier on a housekeeping core sat inside a distribution that was better than the
# baseline at every percentile -- so ranking a tuning change on max alone reports noise as
# a regression. Max is still printed, because for audio it is the number that decides
# whether you get an xrun; it is just not what the ratio is computed from.
# Group by DURATION as well as board and kernel. A longer run sees rarer events, so its
# max is higher for reasons that have nothing to do with the change under test -- pairing
# a 300s run against a 60s one would report the extra sampling as a regression. Only
# compare runs that sampled for the same length of time.
def run_duration(d):
    ds = {c.get("duration_s") for c in d["cyclictest"].values()}
    return ds.pop() if len(ds) == 1 else None

tune = {}
for d in runs:
    iso = d["tunables"].get("isolated_cpus", "unknown")
    dur = run_duration(d)
    if iso == "unknown" or dur is None:
        continue
    tune.setdefault((d["board"], d["kernel"], dur), {}).setdefault(bool(iso), []).append(d)

for (bd, kern, dur), g in sorted(tune.items(), key=lambda kv: kv[0][2]):
    if True not in g or False not in g:
        continue
    off, on = g[False][-1], g[True][-1]
    print("TUNING HEAD TO HEAD  %s  %s  (%ss per period)" % (bd, kern, dur))
    print("  isolated cpus: none  ->  %s" % on["tunables"]["isolated_cpus"])
    print("  %-7s %-22s %-22s %s" % ("frames", "untuned p99.9/max", "tuned p99.9/max", "p99.9 gain"))
    for k in sorted(set(off["cyclictest"]) & set(on["cyclictest"]), key=int):
        a, b = off["cyclictest"][k], on["cyclictest"][k]
        pa, pb = a.get("p99_9_us"), b.get("p99_9_us")
        gain = "%.1fx" % (pa / pb) if pa and pb else "-"
        print("  %-7s %-22s %-22s %s"
              % (k, "%sus / %sus" % (pa, a["max_us"]), "%sus / %sus" % (pb, b["max_us"]), gain))
    print()

# Head-to-head on the most comparable pair: same board, same governor and cap.
by = {}
for d in runs:
    key = (d["board"], d["tunables"].get("governor"), d["tunables"].get("scaling_max_khz"))
    by.setdefault(key, []).append(d)

for key, group in by.items():
    rt = [d for d in group if d["realtime"]]
    non = [d for d in group if not d["realtime"]]
    if not rt or not non:
        continue
    r, n = rt[-1], non[-1]
    print("HEAD TO HEAD  %s  governor=%s cap=%s" % (key[0], key[1],
          ("%dMHz" % (int(key[2]) // 1000)) if str(key[2]).isdigit() else key[2]))
    print("  %-7s %-16s %-16s %s" % ("frames", n["kernel"], r["kernel"], "improvement"))
    for k in sorted(set(n["cyclictest"]) & set(r["cyclictest"]), key=int):
        a, b = n["cyclictest"][k]["max_us"], r["cyclictest"][k]["max_us"]
        print("  %-7s %-16s %-16s %.1fx" % (k, "max %dus" % a, "max %dus" % b, a / b))
    print()
PY
