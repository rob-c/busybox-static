---
title: "`--brief` in run and sh is per stream; sh --timeout is refused"
kind: "instruction"
summary: "`run --brief stdout|stderr|both` and `sh --brief …` reduce output through `brief -d` per stream; `sh --timeout` is refused (ash resets signal dispositions) — use `run --timeout`."
tags: [brief, run, sh, ash, patch-0004, patch-0008, timeout]
created: "2026-11-22T17:50:49.160Z"
updated: "2026-11-22T17:50:49.160Z"
---
`--brief WHICH` reduces a command's output through `brief -d` in `run` and `sh`, with the same words as `log --stream`: `stdout` (default when the value is omitted), `stderr`, or `both`. `run --timeout` already exists and is the sanctioned way to bound a command; `sh --timeout` is refused with a pointer to it because ash cannot honour it.

```text
  run --brief stdout -- sh -c '…'      view reduced, stderr_view raw
  run --brief both    -- cmd           both views reduced
  run --brief nope                     "run: --brief is stdout, stderr or both"  exit 2
  sh  --brief both -c '…'              both shell streams piped through one reducer each
  sh  --timeout 1 -c 'sleep 5'         refused: "use 'busybox run --timeout SECS -- sh -c CMD'"  exit 2
```

## How the reduction is wired

The reducer is invoked **in a forked child** that calls `brief_main_main()` with its own argv (`{"brief","-d"}`), so busybox's global `getopt32` state is private to that child. `run` opens the artifact and pipes it in; `sh` pipes its own fd (`ash_brief_stream`) and restores the *original* stdout/stderr inside the reducer's child — without that, the second reducer's marker line lands in the first reducer's pipe and both views interleave.

Artifacts on disk are never rewritten: `log RUN` still returns the raw bytes, which keeps the "captured execution" promise intact.

## Why `sh --timeout` is refused

ash resets signal dispositions for signals it does not manage while it waits for an external command. A handler installed at startup for `SIGALRM`, `SIGTERM` or `SIGUSR1` is therefore default by the time it matters — measured: `sh --timeout 1 -c 'sleep 5'` died with 142/143/158 and the process-group kill never ran. A watchdog process has the same problem because the shell itself must exit 3. Use `busybox run --timeout SECS -- sh -c CMD`, which enforces the deadline from outside the shell and reports `timed_out=true` with exit 3.

Suite: agent-ops 1299 passed, core 198 passed; `busybox patchcheck` -> checked=14 bad=0.
