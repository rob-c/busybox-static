---
title: "50 checks on the reaper: signals × guests × hygiene × nesting"
kind: "instruction"
summary: "`tests/reaper.sh` has 50 checks (5 signals × 3 guest shapes per applet, hygiene, no premature kill, nesting, concurrency); probes must run the wrapper in the foreground and unblock after 3 s."
tags: [tests, reaper, signals, run, sh, almalinux]
created: "2026-11-22T20:24:33.512Z"
updated: "2026-11-22T20:24:33.512Z"
---
`tests/reaper.sh` holds 50 checks on the watchdog that `run` and `sh` fork (the reaper). Run it with the built binary; it passes 50/50 on darwin-arm64 and in `almalinux:9`.

```text
  A  run × {TERM,INT,HUP,QUIT,KILL} × {plain, ignores-everything, grandchild}   15
  B  sh  × {TERM,INT,HUP,QUIT,KILL} × {plain, background child, ignoring child} 15
  C  watchdog hygiene: none after success, none after kill, output intact,
     run id and pgid still reported                                             8
  D  no premature kill while the wrapper lives; exit codes and --timeout unchanged 6
  E  nested wrappers (sh inside sh, run inside run), outer killed                2
  F  three concurrent runs stopped together, no stray guest                      4
```

## Two rules that make the probes honest

- **Run the wrapper in the foreground.** bash starts background jobs with `SIGINT` ignored, so a backgrounded probe measures the harness: `probe run INT …` reported "alive" until the wrapper ran in the foreground with a helper process sending the signal.
- **Unblock after 3 s.** The helper sends the signal and then, if the target is still alive, `kill -9`s it. Without that cap, one wrong expectation parks the suite in a `while :; do :; done` guest forever — which is exactly how the first draft hung with `sh ... trap '' TERM; while :; ...` (signalling the shell that ignores the signal is not a reaper failure, it is the wrong test).

## Guest shapes matter per applet

For `sh`, `$$` *is* the wrapper, so a guest that traps TERM in the shell itself survives by design. The ignoring guest must be a **child**: `sh -c 'trap "" TERM; …' & wait`. For `run` the guest is always a separate process, so traps inside it are fair game.

## Publishing the guest pid

`echo $$ >> $PIDF` records the guest; for a background child `echo $! >> $PIDF`. A test that reads the wrong line reads the *test script's* pid and reports "alive" forever — nested cases append a third line, so read the specific line, not `tail -1`.

Portability: count matches with `pgrep -f PATTERN | wc -l` (busybox `pgrep` has no `-c`) and avoid `ps -p` (busybox `ps` has none).
