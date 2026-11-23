---
title: "Darwin hides CLOCK_MONOTONIC_RAW, so ns stamps fell back to 1 µs"
kind: "gotcha"
summary: "`CLOCK_MONOTONIC_RAW` is hidden by POSIX feature macros on Darwin, so ns stamps silently fell back to 1 µs `CLOCK_MONOTONIC`; define it (value 4) and res_ns goes 1000 → 41."
tags: [time, darwin, nanoseconds, timeline, release, patch-0020]
created: "2026-11-23T16:17:22.362Z"
updated: "2026-11-23T16:17:22.362Z"
---
A build that defines `_POSIX_C_SOURCE` does not see `CLOCK_MONOTONIC_RAW` on Darwin, so the nanosecond timeline silently fell back to `CLOCK_MONOTONIC` — which is quantised to **1 µs** on this hardware. Defining the constant (ABI value 4) when the header hides it restores 41 ns.

```text
  run -t -n -- …        before: stamp=ns res_ns=1000     (1 us, MONOTONIC)
                        after:  stamp=ns res_ns=41       (24 MHz, MONOTONIC_RAW)

  measured on this Mac, 20000 samples of "smallest non-zero delta":
      CLOCK_MONOTONIC_RAW = 41 ns      CLOCK_MONOTONIC = 1000 ns
```

## Why the fallback was invisible

`#if defined(__APPLE__) && defined(CLOCK_MONOTONIC_RAW)` looks correct and compiles either way. When the name is hidden the `#else` branch runs `clock_gettime(CLOCK_MONOTONIC, …)` — still a monotonic clock, still nanosecond *fields*, so nothing fails; only the resolution collapses. `tests/agent-ops-sweep.sh` caught it because it asserts `res_ns < 1000`, and the header had been advertising `stamp=ns` all along.

Fix in `libbb/time.c`: define the constant for Apple when absent, with a comment stating why a hard-coded ABI number is the lesser evil than a silent 24× resolution loss.

## Releasing on a shared tree

- `git commit`/`git tag` fail with "Committer identity unknown" on this machine; pass `-c user.name=… -c user.email=…` per invocation rather than writing a global config.
- A long suite can exceed the harness's per-call deadline even when `timeout` is raised: run it as `(nohup ./tests/x.sh … > log 2>&1 &)` and read the log, instead of losing the run to a kill.
- Re-pack **after** any last-minute source fix: the bundle is rebuilt in place under `release/<stamp>/`, so notes generated before the rebuild describe binaries that no longer exist.

Verified on the published asset: `shasum -a 256 -c` OK, `run -t -n … → res_ns=41`, `unzip -q r.zip -d outd` extracts 1 file.
