---
title: "top on Darwin: memory from three counters, and why STAT shows R"
kind: "discovery"
summary: "top works on Darwin at 255 applets: map each memory column to its own Mach counter, skip xchdir(/proc), and accept that macOS reports SRUN for every process so STAT cannot show S."
tags: [darwin, top, proc_pidinfo, host_statistics, vm_statistics64, kconfig, getcpu_count]
created: "2026-11-21T20:15:27.458Z"
updated: "2026-11-21T20:17:16.812Z"
---
`top` runs on Darwin (255 applets) with a real Mem/CPU/Load-average header and per-process `%RSS`/`%CPU`. Two findings are worth keeping: the memory line needs three separate Mach counters, and macOS will not tell you whether a process is sleeping.

```text
 top's Linux assumption          Darwin source
 /proc/stat (cpu line)           host_statistics(HOST_CPU_LOAD_INFO) -> cpu_ticks[4]
                                 (usr/nic/sys/idle; iowait/irq/softirq/steal = 0)
 /proc/meminfo                   hw.memsize + host_statistics64(HOST_VM_INFO64)
                                 + sysctl vm.swapusage
 /proc/loadavg                   getloadavg(3)
 xchdir("/proc")                 must be skipped: there is no /proc to chdir to
 /proc/PID/stat utime/stime      proc_pidinfo(PROC_PIDTASKINFO).pti_total_{user,system}
 /proc/PID/stat rss              pti_resident_size >> 10  (KB, what top expects)
```

## The memory line needs these three, not `struct sysinfo` alone

`bb_sysinfo()` gives `totalram`/`freeram`/`bufferram`, but `sharedram` is never filled, so mapping top's `cached` column from it prints `0K`. Fill each column from the source that actually measures it:

| top column | expression |
|---|---|
| MemTotal | `hw.memsize >> 10` |
| MemFree | `(free_count + speculative_count) * vm_page_size >> 10` |
| buff | `(purgeable_count + wire_count) * page >> 10` |
| cached | `(inactive_count + purgeable_count) * page >> 10` |

Linux's `used` is `MemTotal - MemFree` and deliberately includes cache, so keep that formula and the header reads sensibly: `Mem: 100038048K used, 34179680K free, 0K shrd, 11982624K buff, 41203264K cached`.

## macOS reports SRUN for every process

`kinfo_proc.kp_proc.p_stat` and `proc_bsdinfo.pbi_status` both return **2 (SRUN)** for a `sleep 30` that `/bin/ps` reports as `S`. `PROC_PIDT_SHORTBSDINFO` returns 2 as well. Verified with a three-line C probe:

```text
 /bin/ps 54314       -> S
 proc_pidinfo BSD    -> status=2
 kinfo_proc          -> p_stat=2
 SHORTBSDINFO        -> pbsi_status=2
```

So `ps` and `top` cannot distinguish running from sleeping through any public API, and our `STAT` column shows `R` where Apple's shows `S`. Do not "fix" this by guessing from CPU time — document it.

## Profiling a whole class of bugs

`top`, `mpstat` and `vmstat` all failed with `can't open '/proc/...'` for the same non-obvious reason: the reader lives in **libbb**, not in the applet. `get_cpu_count()` opened `/proc/stat` from `mpstat_main()` before any applet code ran. Grep for the path string across `src/`, not for the applet's `PROCFS_*` macro.

## Enabling dependent Kconfig symbols

Setting `CONFIG_TOP=y` alone leaves `FEATURE_TOP_CPU_USAGE_PERCENTAGE`, `FEATURE_TOP_CPU_GLOBAL_PERCENTS` and `FEATURE_TOP_DECIMALS` at `n`, because they were disabled while `TOP` was off. Edit `build/<target>/.config` and run `make O=build/<target> oldconfig` by hand; a subsequent `./build.sh` then preserves them. Without them `top` prints no `CPU:` line and no `%CPU` column, and `--list` will be one applet short of the expected count.
