---
title: "`sh --timeout` dispatches to `run --timeout`, because ash drops signal handlers"
kind: "discovery"
summary: "`sh --timeout N` exits 3 by dispatching in-process to `run --timeout N --quiet`; ash resets signal dispositions while waiting on a child, so no in-shell alarm can work."
tags: [sh, ash, timeout, run, quiet, patch-0004, patch-0008]
created: "2026-11-22T17:56:41.932Z"
updated: "2026-11-22T17:56:41.932Z"
---
`busybox sh --timeout N` enforces a deadline on a shell command or script, exiting **3** when it expires, and it does that by handing the work to the `run` applet rather than by alarming the shell. `run --quiet` (new) prints only the captured streams, so the output is what a plain shell would print.

```text
  sh --timeout 1 -c 'echo start; sleep 5'   ->  start                       exit 3
  sh --timeout 5 -c 'exit 7'                ->  (no output)                 exit 7
  sh --timeout 5 script.sh                  ->  script output               exit as script
  sh --timeout 5 --brief stdout -c '…'      ->  [brief] marker + reduction  exit 0
  sh --timeout 1                            ->  --timeout needs -c CMD …   exit 2
```

## Why the deadline lives in `run`, not in ash

Three in-shell mechanisms were measured and all failed the same way — the handler is gone by the time it matters:

| attempt | observed exit |
|---|---|
| `alarm(1)` + SIGALRM handler | 142 |
| watchdog process + SIGTERM handler | 143 |
| watchdog process + SIGUSR1 handler | 158 |

ash resets signal dispositions for signals it does not manage while it waits on an external child, so the shell dies by the signal's default action instead of running the handler that would `_exit(3)`. A `trap` is no help either: traps are drained at evaltree/dotrap points, and the shell is parked in `waitpid` for the sleep it is supposed to cancel.

`ash_dispatch_timeout()` therefore rewrites the invocation into `run --timeout N --quiet [--brief WHICH] -- sh <original args>` and calls `run_applet_no_and_exit()` in-process — no exec, no second busybox on disk. One implementation owns the deadline, the SIGTERM→SIGKILL escalation and the process-group kill; the shell only supplies the argv. Run artifacts are still written, so `log` can show the raw output afterwards.

## Contract notes

- Exit codes stay in 0/1/2/3: timeout is 3, usage error is 2, a child's own code passes through.
- `sh --timeout` with neither `-c` nor a script is refused rather than becoming an interactive shell with a deadline.
- `--brief` composes: when both flags are given, ash forwards `--brief` to the run it dispatches.

Suite: agent-ops 1299 passed, core 198 passed; `busybox patchcheck` -> checked=14 bad=0.
