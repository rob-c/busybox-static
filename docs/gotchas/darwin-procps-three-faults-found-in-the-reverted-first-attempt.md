---
title: "Darwin procps, attempt two: ps fixed, argv_len overrun still breaks killall"
kind: "gotcha"
summary: "Second Darwin procps attempt: ps is right once the argv walk is bounded by argc, but argv_len still runs into env for some pids, so pidof/killall over-match — revert, bound the walk, then match."
tags: [darwin, procps, sysctl, ps, killall, argv-len]
created: "2026-11-21T16:54:52.670Z"
updated: "2026-11-21T16:59:47.369Z"
---
A second, more careful `procps_status_t` implementation over `KERN_PROC_ALL` + `KERN_PROCARGS2` got `ps` right and made `pidof`/`killall`/`pgrep` respond, but it still had to be reverted: `pidof`/`killall` over-matched (they would signal the wrong processes) and `ps` still leaked environment text into 6 of ~1380 COMMAND cells. Both faults point at `argv_len` being too long for some processes.

```text
 KERN_PROCARGS2: [argc][exec\0][argv0\0][argv1\0]…[env\0]…
                        ^ walk argc strings, stop here ^   ← env starts after
 what worked          what is still wrong
 ps COMMAND           argv_len occasionally spans into env → COMMAND shows PATH=…
 pgrep -f / pkill -f  pidof/killall match extra /bin/sh processes (same root cause)
```

## What the second attempt established

* **Ajax the iterator must not live in `procps_status_t`.** Callers memset that struct per process; keeping the cursor there made every call restart. A file-static `{procs, count, idx}` snapshot fixed iteration.
* **`ps` needs the argv walk bounded by `argc`**, not by the buffer end — that was the whole "environment instead of command line" bug, and it is fixed: `ps` now prints `/bin/sh /tmp/agenttestproc` correctly.
* **`PSSCAN_ARGVN` is not `PSSCAN_ARGV0`.** It is `(1 << 16) * ENABLE_KILLALL…`, a separate high bit, so `killall`/`pidof` were never getting argv. Filling argv on every scan fixed the matching path existing at all — and then exposed the over-match.
* **macOS reports the interpreter in `p_comm` for scripts** (`/bin/sh`), with the script path in `argv[1]`, which is why matching must scan the argv list and not just `argv[0]`.

## What remains, precisely

Bound `argv_len` strictly to the walked region and prove it before matching: for a handful of pids (kernel tasks, launchd children, `sh -c` children) the walk appears to run past the last argument into the environment, so `bb_basename()` comparisons and `read_cmdline()` both see env strings. Assert `q <= end` after every step and set `argv_len` only from the bytes actually walked; then `pidof`/`killall` should stop matching `/bin/sh` processes and `ps` should stop showing `PATH=`.

Verified working before the revert: `ps` (1379 rows, correct COMMAND), `pgrep -f`, `pkill -f`. The revert restored `libbb/procps.c`, `procps/ps.c`, `libbb/find_pid_by_name.c` and `prune/darwin-off.txt`, so `ps`/`pgrep`/`pkill`/`pstree`/`pidof` remain off in the Darwin build; 160/160 tests and 259 stress checks pass.
