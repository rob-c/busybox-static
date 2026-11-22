---
title: "mpstat works on Darwin: the /proc reader was get_cpu_count() in libbb"
kind: "gotcha"
summary: "mpstat works on Darwin at 254 applets: the /proc/stat open was get_cpu_count() in libbb, not mpstat.c — grep the path string tree-wide, and guard host_processor_info's count/array mismatch."
tags: [mpstat, darwin, getcpu_count, host_processor_info, libbb, debugging]
created: "2026-11-21T19:29:22.979Z"
updated: "2026-11-21T20:06:22.288Z"
---
`mpstat` now works on Darwin (254 applets) and prints real per-CPU percentages. The mysterious `/proc/stat` open that defeated six earlier attempts was not in `mpstat.c` at all — it was `get_cpu_count()` in `libbb/get_cpu_count.c`, which `mpstat_main()` calls before any parsing.

```text
 mpstat: can't open '/proc/stat'
        |
        +-- get_cpu_count()          <-- THE CULPRIT, in libbb, not mpstat.c
        |     opens /proc/stat to count "cpuN" lines
        +-- get_cpu_statistics()     guarded: delegates to mpstat_cpu_darwin()
        +-- get_irqs_from_stat()     guarded: returns early
        +-- get_irqs_from_interrupts() guarded: returns early
        +-- get_irqcpu_nr()          guarded: returns 0
```

## Why the earlier disassembly "proved" the dispatch worked

`llvm-objdump` showed `_get_cpu_statistics` calling `_host_processor_info`, so the delegation had compiled correctly all along. The run still died, because the fatal open happened earlier, in a *different translation unit*. Grepping for `PROCFS_STAT` in `mpstat.c` could never find it: the path is a literal `"/proc/stat"` in libbb.

**Lesson: when an error says `/proc/stat`, grep the whole tree for the *path string*, not for the applet's macro.** `rg -n '"/proc/stat"' src/` finds every reader in one shot.

## The fix, two parts

1. `libbb/get_cpu_count.c`: on `__APPLE__`, `sysctlbyname("hw.ncpu", ...)` and return it; the `/proc/stat` scan stays in the `#else`. `#include <sys/sysctl.h>` is required — without it the build fails with "call to undeclared function 'sysctlbyname'".
2. `procps/mpstat.c`: Darwin collectors above the first `/proc` reader, then a **delegating early return** as the first statement of each reader (`get_cpu_statistics`, `get_uptime`, `get_irqs_from_stat`, `get_irqs_from_interrupts`, `get_irqcpu_nr`). Delegation rather than a two-line dispatcher means no name resolution can be bypassed.

## The `host_processor_info` count trap

`host_processor_info` returns CPU **count** in the `natural_t*` out-parameter and int/float **array size** in `mach_msg_type_number_t*` — the opposite of what the parameter order suggests, and it differs from `host_statistics`. On this machine it returned `ncpu=72` (18 CPUs × 4 ints) and `ncpu_nat=18`, which allocated 72 CPU slots and printed 72 mostly-zero rows. Guard it and clamp to the array that `alloc_struct()` already sized:

```c
if (ncpu != ncpu_nat && ncpu == ncpu_nat * 4) ncpu = ncpu_nat;
if ((int)ncpu > G.cpu_nr) ncpu = G.cpu_nr; else G.cpu_nr = ncpu;
```

## Verified output

`busybox mpstat` → 18 CPUs, `all 29.05 %usr / 7.25 %sys / 63.71 %idle`. `-P ALL` lists CPU 0-17. `-I SUM` prints 0.00 intr/s (macOS has no interrupts counter), and the interrupt collectors return early instead of opening `/proc`. `mpstat 1 1` gives a second row and a sane Average. `vmstat` still correct, `./test.sh` 168/168.
