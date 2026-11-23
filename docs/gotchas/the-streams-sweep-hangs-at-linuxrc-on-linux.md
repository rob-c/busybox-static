---
title: "The streams sweep hangs at linuxrc on Linux"
kind: "gotcha"
summary: "`tests/streams.sh` hangs at the applet `linuxrc` on Linux: it ignores SIGTERM, so the sweep's `timeout 2` cannot stop it; add it to the skip list rather than raising the timeout."
tags: [tests, streams, linuxrc, hang, linux]
created: "2026-11-22T23:37:33.023Z"
updated: "2026-11-22T23:37:33.023Z"
---
`tests/streams.sh` sweeps every applet with an argument it must reject. On Linux that sweep hangs at `linuxrc`, the 157th applet: `linuxrc` is init-like, ignores `SIGTERM`, and the sweep's own `timeout 2` therefore cannot stop it — the suite stops printing and never reaches its summary. On Darwin the applet does not exist, which is why the same script is green there.

## The rule

`linuxrc` belongs in the skip list next to `init`, `login` and the daemons, and it is now there with a comment saying why. When adding a new applet to a Linux build, check that it terminates on `SIGTERM` before letting the sweep reach it; anything that installs its own `TERM` handling (init, linuxrc, watchdog-style applets) must be skipped, not "timed out".

## Symptom to recognise

The suite prints sections up to the applet sweep and then nothing, with no `FAIL` line: a hang inside a sweep that has no per-applet progress output. Run it under `bash -x` and look at the last `for a in $("$BB" --list)` iteration to find the applet.
