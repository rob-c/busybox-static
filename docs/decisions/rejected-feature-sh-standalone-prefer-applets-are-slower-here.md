---
title: "Rejected: FEATURE_SH_STANDALONE / PREFER_APPLETS are slower here, and shadow builtins"
kind: "decision"
summary: "Enabling FEATURE_SH_STANDALONE/PREFER_APPLETS makes shell loops 0.5-0.64x slower on macOS and makes applets shadow shell builtins like echo — leave both off; measured, not assumed."
tags: [standalone, prefer-applets, performance, benchmark, shell, decision]
created: "2026-11-21T15:04:47.054Z"
updated: "2026-11-21T15:04:47.054Z"
---
Turning on `CONFIG_FEATURE_SH_STANDALONE` + `CONFIG_FEATURE_PREFER_APPLETS` looks like an easy win for an agent toolbelt (applets dispatched in-process instead of `fork`+`exec`, so thousands of tiny commands get faster). Measured on this port, it is a **loss**, and it changes behaviour. Don't enable it here.

Measurements: same source and `.config`, Darwin arm64, best of 3, 200 iterations of a POSIX `while` loop inside `busybox sh -c`:

| loop body | normal build | standalone build | result |
|---|---|---|---|
| `basename /usr/lib/libfoo.dylib` | 1.62 s | 2.54 s | **0.64x** |
| `wc -l < /etc/services` | 1.59 s | 3.16 s | **0.50x** |
| `grep -c root /etc/passwd` | 1.69 s | 2.95 s | **0.57x** |
| `echo x >/dev/null` | 0.032 s | 0.063 s | **0.51x** |

```mermaid
flowchart LR
  A["agent: sh -c 'grep ...'"] --> B{standalone on?}
  B -->|no| C["PATH lookup -> fork+exec"]
  B -->|yes| D["applet found by name<br/>fork, call main() in child"]
  D --> E["also wins over shell builtins:<br/>echo now forks too"]
  C --> F["1.69 s / 200 calls"]
  E --> G["2.95 s / 200 calls"]
```

## Why it loses here

The speedup folklore comes from Linux, where `NOFORK` applets are called with no process at all. `basename`, `wc` and `grep` are `NOEXEC` (fork, then call `main()` in the child), so the saving is one `exec` — which on Darwin is cheap relative to fork plus busybox's per-run initialisation (locale/unicode setup, applet table scan). The third mode, `fork` + `exec /proc/self/exe`, cannot work on macOS at all, since there is no `/proc`.

## Why it is also a behaviour change

The option makes **applets take precedence over shell builtins of the same name**. `echo` stops being a builtin and becomes an applet invocation — visible above as a 2x slower `echo` loop. For scripts, that is a semantic change nobody asked for.

## What to do instead

Leave both off. If per-command latency matters, the real lever is not dispatch: it is running fewer processes (builtins, `xargs -P`, `flock`), or shipping `ripgrep` for search — `busybox grep -rl` over 3086 files took 0.752 s against `rg -l` 0.056 s (13x).
