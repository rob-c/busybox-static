---
title: "Darwin CLOCK_MONOTONIC is 1 µs quantised; only MONOTONIC_RAW gives 41 ns"
kind: "discovery"
summary: "Darwin's CLOCK_MONOTONIC is quantised to 1 µs while CLOCK_MONOTONIC_RAW gives 41 ns, so keep RAW on Apple; the ns check was right and I was wrong to blame it."
tags: [clock, darwin, nanoseconds, monotonic, testing]
created: "2026-11-23T14:21:01.432Z"
updated: "2026-11-23T14:21:01.432Z"
---
Darwin's `CLOCK_MONOTONIC` is **quantised to 1 µs**; only `CLOCK_MONOTONIC_RAW` exposes the 24 MHz tick (41.7 ns). Swapping to `CLOCK_MONOTONIC` on both platforms for "parity" therefore silently destroyed the nanosecond stamps — and the ns suite caught it, `res_ns=1000` where it had been 41.

```mermaid
flowchart LR
  A["CLOCK_MONOTONIC_RAW<br/>darwin"] --> B["res_ns=41"]
  C["CLOCK_MONOTONIC<br/>darwin"] --> D["res_ns=1000<br/>µs quantised"]
  E["CLOCK_MONOTONIC<br/>linux"] --> F["res_ns=41-45"]
```

## The measurement

```
$ busybox run -t -n -- busybox echo hi      # with CLOCK_MONOTONIC on darwin
timeline_lines=1 shown=1 truncated=false stamp=ns res_ns=1000
$ busybox run -t -n -- busybox echo hi      # with CLOCK_MONOTONIC_RAW
timeline_lines=1 shown=1 truncated=false stamp=ns res_ns=41
```

Same binary, same probe (20,000 consecutive reads, smallest non-zero delta), one clock constant apart.

## The trade, decided

`CLOCK_MONOTONIC_RAW` keeps counting while the machine sleeps, while Linux's `CLOCK_MONOTONIC` does not, so a stamp spanning a suspend differs by the sleep duration. Resolution wins: a timeline is read for ordering and spacing, and a 1 µs floor was the thing the ns work existed to remove. `src/libbb/time.c` now uses RAW under `__APPLE__` and `CLOCK_MONOTONIC` everywhere else, with the reason in a comment.

## The lesson about tests

I had recorded the failing check `stamp-ns resolution is ns-scale (< 1us)` as "my broken check". It was not broken — it was doing its job, correctly reporting a regression I had just introduced. A test that fails after a change is evidence, not noise; check the measurement before touching the assertion.

Suite after the fix: `sweep 1267/0/8sk`, `agent-ops 1299/0`, `patchcheck checked=21 bad=0`.
