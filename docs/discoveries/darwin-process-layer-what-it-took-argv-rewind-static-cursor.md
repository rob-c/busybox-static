---
title: "Darwin process layer: what it took (argv rewind, static cursor, safe matching)"
kind: "discovery"
summary: "Darwin ps/pgrep/pkill/killall/pidof work via KERN_PROC_ALL + KERN_PROCARGS2: cursor in a static snapshot, argv walk rewinds at the env boundary, matching is comm/argv0/shell-argv1 only."
tags: [darwin, procps, sysctl, ps, killall, argv, matching]
created: "2026-11-21T17:21:22.658Z"
updated: "2026-11-21T17:21:22.658Z"
---
The Darwin process layer works: `ps`, `pgrep`, `pkill`, `pstree`, `pidof` and `killall` are now in the Darwin build (242 applets, was 236). It took three attempts; the two bugs that mattered are both in the argv handling.

```text
 KERN_PROCARGS2: [argc][exec\0][argv0\0][argv1\0]…[KEY=value\0][KEY=value\0]…
                          └──── walk at most argc strings ────┘
                                                     ↑
                      stop here on the first KEY=value AND rewind the pointer
```

## The two bugs

1. **The iteration cursor must not live in `procps_status_t`.** `ps`, `pgrep` and friends treat that struct as scratch and `memset` it for every process, so a cursor stored in `sp->dir` (as `(DIR *)(uintptr_t)idx`) restarts every call. The snapshot lives in a file-static `{struct kinfo_proc *procs; int count; int idx;}` instead, refilled when exhausted.
2. **The argv walk needs three bounds, and the environment guard must rewind.** `argc` alone is not enough: for some processes it overruns into the environment. Bound by `argc`, by `DARWIN_ARGV_MAX_BYTES`, and stop at the first string containing `=` that does not start with `-`, `/` or `.` — and set the pointer back to that string before breaking. Without the rewind, `ps` printed `PATH=/Users/…` in the COMMAND column for 11 processes.

## Name matching (and what it must not do)

`p_comm` holds the *interpreter* for scripts, so `/bin/sh /path/tool` reports `sh`. Matching is: `p_comm`, then `basename(argv[0])`, then `basename(argv[1])` **only when `argv[0]` is a shell or interpreter** (`sh bash zsh dash ksh csh tcsh python* perl ruby node php`). Scanning every argv element was the first thing I tried and it over-matched — `pidof agenttestproc` returned 5 pids, including `grep agenttestproc`, which would make `killall` a foot-gun. Argument matching is `pkill -f`'s job.

## Verified

`ps` header/rows/`-o pid,ppid,user,comm`; zero `KEY=` in column 4; `pidof` returns exactly one pid for a script; `killall -0` exits 0 and `killall` stops the process; `pkill -f` kills by full command line; `pstree` prints the tree. Covered by `test.sh`'s `proc:` checks (168 total), 259 stress checks, all five Darwin artifacts and all six build targets.
