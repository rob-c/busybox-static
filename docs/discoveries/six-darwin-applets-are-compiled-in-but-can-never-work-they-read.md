---
title: "Six Darwin applets are compiled in but can never work: they read /proc"
kind: "discovery"
summary: "The Darwin build ships applets whose source hard-codes /proc, so they fail with \"can't open '/proc'\" every time; drop them from the config or port them, don't ship them silently."
tags: [darwin, proc, applets, config, killall, lsof]
created: "2026-11-21T13:56:51.202Z"
updated: "2026-11-21T13:56:51.202Z"
---
Several applets are present in the Darwin binaries yet fail on every invocation because their own source opens `/proc`, which macOS does not have. They were not pruned because `prune/darwin-off.txt` works by category, and these sit in categories that are otherwise portable.

```mermaid
graph LR
  A["agent: killall dev-server"] --> B[killall, procps/kill.c]
  B --> C["find_pid_by_name()<br/>libbb/find_pid_by_name.c"]
  C --> D["walk /proc/*/stat"]
  D --> E["killall: can't open '/proc'"]
  E --> F["agent burns turns on an<br/>error it cannot fix"]
```

Measured on `dist/darwin-arm64/bin/busybox`:

| applet | result |
|---|---|
| `killall -0 launchd` | `killall: can't open '/proc': No such file or directory` |
| `lsof -p $$` | `lsof: can't open '/proc'` |
| `vmstat`, `mpstat`, `iostat` | `vmstat: can't open '/proc/stat'` |
| `pwdx $$` | `pwdx: 52925: No such process` |

`killall` is the costly one: killing a stale dev server is a routine coding-agent step.

## Which applets really are /proc-dependent

Grepping `/proc` per source file overstates it — `netstat`, `less`, `ash`, `httpd` and `mountpoint` all mention `/proc` and all work. The ones that actually fail are: `iostat`, `lsof`, `mpstat`, `nmeter`, `pwdx`, `start-stop-daemon`, `sysctl`, `vmstat`, plus `killall`/`pidof`/`pgrep`/`pkill` via `find_pid_by_name` and `procps_scan`.

## What to do

- Drop them from the Darwin `.config` so the applet is absent: an agent then falls back to the macOS native tool instead of burning turns on an error it cannot fix.
- Or port, cheapest first: `find_pid_by_name()` over `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)` (~80 lines) buys `killall` and `pidof`; a `procps_status_t` layer (`libbb/procps.c` is 656 lines of `/proc`) buys `ps`/`pgrep`/`pkill` but costs ~250. `lsof`, `vmstat`, `iostat`, `mpstat` are not worth porting.
