---
title: "Concurrent runs share an artifact id unless mkdir claims it"
kind: "gotcha"
summary: "Concurrent `run` calls in one artifact root chose the same run id and truncated each other's artifacts; claim the id with mkdir and re-scan on EEXIST instead of tolerating it."
tags: [run, artifacts, concurrency, race, mkdir]
created: "2026-11-22T23:37:24.006Z"
updated: "2026-11-22T23:37:24.006Z"
---
Two runs of `run` in the same artifact root could pick the same run id: `next_run_id()` scans for the highest `R<n>`, then `mkdir` was allowed to fail with `EEXIST` and the run kept going. The second run then opened `R1/stdout` with `O_TRUNC` and overwrote the first run's evidence, so `log R1` showed the wrong command's output and `--quiet` printed another process's stream. It surfaced as "three concurrent pty runs all print `only-1`" and "three concurrent runs produce only two distinct tty names".

```text
  A: scan → max=0 → id=1 ─┐
  B: scan → max=0 → id=1 ─┴─► both mkdir("R1"): one wins, the other gets EEXIST
      before: EEXIST tolerated → same dir → O_TRUNC → evidence clobbered
      after:  EEXIST → re-scan → id=2 → own dir
```

## The rule

The id must be *claimed*, not computed: `mkdir` is atomic, so loop on `EEXIST`, re-scanning for the next free id, and give up after a bounded number of tries. Tolerating `EEXIST` is only correct if two runs sharing a directory is the intended behaviour, which it is not — `log`, `--prune` and the `stdout`/`stderr`/`meta` names all assume one run per directory.

## How to test it

Three concurrent `run` calls with the *same* `-D` and different output, then compare: distinct `pty_slave` values and each run's own text. Per-run `-D` directories hide the bug, so the concurrency checks in `tests/pty.sh` deliberately share one root.
