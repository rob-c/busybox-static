---
title: "A watchdog process kills the guest when busybox is killed"
kind: "architecture"
summary: "`run`/`sh` fork a watchdog in its own process group that SIGKILLs the guest group when the wrapper dies, covering SIGKILL; the watchdog must close inherited fds and be reaped before returning."
tags: [run, sh, signals, sigkill, watchdog, patch-0004, patch-0008]
created: "2026-11-22T19:52:34.204Z"
updated: "2026-11-22T19:52:34.204Z"
---
`busybox run` and `busybox sh` now kill the command's process group when the wrapper itself is killed, including by `SIGKILL`. The mover is a small watchdog process in its own process group, not a signal handler, because SIGKILL cannot be caught.

```text
  busybox run -- sh -c 'sleep 30'
     ├─ child: sh -c …, setpgid(0,0)      → guest group = child pid
     ├─ fork: watchdog (setpgid(0,0))     → own group, survives group kills
     └─ watchdog: poll kill(getppid(),0) → when the wrapper is gone:
                  kill(-guest_group, SIGKILL)
```

```
$ busybox run --quiet -- sh -c 'sleep 30 & echo $! > p; wait' &
$ kill -9 $!                # wrapper killed outright
$ kill -0 $(cat p)          # → gone
```

## Why not a handler

Handlers cover TERM/INT/HUP but not SIGKILL, and `ash` also resets dispositions for signals it does not manage while a child runs (measured earlier: 142/143/158 instead of the handler). A watchdog has no such window: it exists for the wrapper's whole life and outlives it.

## Details that matter

- The watchdog must **close every inherited fd** (stdout/stderr/pipes): keeping the capture pipe open makes the parent wait for EOF forever. Symptom: `busybox run -- echo hi` hangs with no output.
- It must be in its **own** process group before the kill, or `kill(-group)` kills it too.
- For `sh`, the group to kill is `getpid()` after `setpgid(0,0)` — computed **in the parent**; computing it in the forked child passes the watchdog's own pid and protects nothing.
- `sh` only moves groups when non-interactive; an interactive shell keeps the terminal's group so job control still works.
- The wrapper kills and reaps its watchdog before returning (`atexit`), otherwise the watchdog lingers up to 100 ms and shows up in process scans — `tests/agent-ops.sh`'s `run.timeout.kills.child` caught exactly that.

`tests/wrapper-signals.sh` covers 21 cases: TERM/INT/HUP/KILL for both applets, a guest that ignores TERM, grandchildren, and unchanged exit codes/output/hygiene. The SIGINT probe must run the wrapper in the **foreground** — bash starts background jobs with SIGINT ignored, so a backgrounded probe measures the harness, not busybox.
