---
title: "`bench`: time a command N times (patch 0012)"
kind: "instruction"
summary: "`busybox bench -n N [-w W] [--format json] -- CMD` reports min/median/max wall time (ms text, µs JSON) and exits 1 if any run fails while still printing the timings."
tags: [bench, applet, patch-0012, timing, agent-features]
created: "2026-11-22T14:36:12.052Z"
updated: "2026-11-22T14:36:12.052Z"
---
`busybox bench` times a command N times and reports min/median/max wall time, so a shell harness can tell a real regression from noise without shelling out to `time` repeatedly. Ships as `patches/0012-agent-ops-bench.patch`.

```text
  bench -n N [-w warmup] [--format json] -- CMD...
        │
        ├─ warmup runs          discarded (default 1)
        ├─ run: fork → execvp → waitpid, timed with CLOCK_MONOTONIC
        └─ summary              min / median / max in ms; JSON uses µs
```

```
$ bench -n 3 -- sh -c 'true'
run=1 ms=16.507 status=0
runs=3 ok=3 failed=0 min_ms=16.507 median_ms=16.624 max_ms=20.506

$ bench -n 3 -w 0 --format json -- sh -c 'true'
{"schema":1,"status":"ok","runs":3,"ok":3,"failed":0,"min_us":16507,"median_us":16624,"max_us":20506,"mean_us":…,"cmd":"sh -c true"}

$ bench -n 2 -- sh -c 'exit 3'      # status=error, exit 1, timings still printed
```

## Details worth knowing

- **A failing run is not a crash**: the applet prints every run's `status` and still summarises, then exits 1 if any run failed. Text mode shows milliseconds, JSON shows microseconds — do not mix them in a comparison.
- `getopt32long` uses a `+` prefix here, so `bench -- sh -c 'echo --format json'` passes those words to the child rather than to `bench`. Options must come before `--`.
- Median is `t[n/2]` of the sorted array (upper median for even counts). `mean_us` is 0 when every run failed.
- As with the other new applets, the entry point is `bench_main_main` and `CONFIG_BENCH=y` needs adding to **both** `EXTRA_CONFIG` blocks in `build.sh`.

## Limits

Wall time only — no CPU time, no per-run stdout capture (use `run` for that). `execvp` failure inside the child shows as `status=127`, so a missing binary looks like a failing child, not a wrapper error.
