---
title: "Detect surviving guests with pid files, not command-line scans"
kind: "gotcha"
summary: "Detect surviving guests by recording `$$`/`$!` into a pid file and using `kill -0`; a cmdline scan misses exec()ed guests and silently passes 200 checks."
tags: [tests, timeout, signals, orphans, portability, almalinux]
created: "2026-11-22T18:33:51.847Z"
updated: "2026-11-22T18:33:51.847Z"
---
`tests/timeout-resilience-matrix.sh` runs 200 deadline checks: 10 hostile guests × 4 invocation paths × 5 assertions. Survivor detection uses **PID files and `kill -0`**, not command-line scanning, because a guest whose last command is `sleep 30` gets exec()ed and loses its marker.

```text
  guests  trap '' TERM | trap '' TERM INT | trap '' TERM INT HUP QUIT
          trap 'sleep 30' TERM | trap 'exit 0' TERM | trap 'exit 3' TERM
          child ignores + wait | subshell ignores | looping sleeps | CPU spin
  paths   run --timeout 1 | run --timeout 1 --kill-after 0.2
          sh --timeout 1   | run --brief --timeout 1
  checks  rc=3 | rc!=124 | rc<128 | no survivor | elapsed <= 8s
```

## The scan that reported green while checking nothing

The first Linux run of the matrix printed **200 passed** and was worthless. The guests were found (or missed) by grepping `ps`/`/proc` command lines for a marker like `m1g`. On Linux `sh -c 'echo m1g; sleep 30'` **exec()s** `sleep 30`, so the surviving process is just `sleep 30` — no marker, never matched, every orphan check vacuously true. Darwin kept the shell alive and hid this.

Fix: each guest starts with `echo $$ >> $PIDF` (and appends `$!` when it spawns a child), and a survivor is a pid where `kill -0` succeeds after the wrapper returns — `/proc/<pid>/stat` state `Z` counts as dead so a zombie is not a failure. No `ps`, no `/proc` scan, no dependency on argv at all.

## Trust the harness before trusting the result

Both suites now begin by leaking a real process (`echo $$ > probe; exec sleep 3`) and **aborting** unless the survivor check finds exactly it. A blind detector stops the run instead of producing a green result — the failure mode above cost an hour of believing a passing suite.

Results: matrix 200/200 on darwin-arm64 and in `almalinux:9`; single-scenario suite 50/50 on both. `almalinux:9` ships no `ps` at all, which is exactly why the pid approach is the portable one.
