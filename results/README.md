# Results

One JSON file per test run. Filename: `<board>-<kernel>-<timestamp>.json`.

Each run records enough to make comparisons honest — not just the numbers, but the
tunables in force when they were measured, since RT results are meaningless without them.

```json
{
  "board": "piv",
  "kernel": "7.0.0-1017-raspi-realtime",
  "realtime": true,
  "config_hash": "sha256:...",
  "timestamp": "2026-09-15T12:00:00Z",
  "tunables": {
    "governor": "performance",
    "rt_runtime_us": -1,
    "irq_priorities": {"xhci_hcd": 95},
    "isolcpus": null
  },
  "load": "stress-ng --cpu 4 --io 2 --vm 1 + dd to USB root",
  "cyclictest": {"interval_us": 1333, "duration_s": 3600,
                 "min_us": 8, "avg_us": 14, "p99_9_us": 41, "p99_99_us": 63, "max_us": 88},
  "audio": {"device": "SSL 2+ Mk II", "rate": 48000, "period_frames": 64,
            "duration_s": 1800, "xruns": 0, "passed": true}
}
```

The headline metric is the audio one: **N frames at 48 kHz for M minutes under load with
zero xruns**. cyclictest's *maximum* is the useful synthetic proxy — the mean is nearly
irrelevant, because one late buffer is one audible xrun.
