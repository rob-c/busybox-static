---
title: "timeout exits 128+signal (143), never 124 — and sleep/timeout fractions need FEATURE_FANCY_SLEEP"
kind: "gotcha"
summary: "timeout returns 143/137 (128+signal), not GNU's 124, so $? cannot reveal a timeout; fractional SECS needs CONFIG_FEATURE_FANCY_SLEEP, and there is no ash sleep builtin."
tags: [timeout, sleep, exit-codes, feature-fancy-sleep, ash]
created: "2026-11-21T23:31:09.634Z"
updated: "2026-11-21T23:31:09.634Z"
---
Both applets are enabled on every target, but their behaviour differs from GNU in ways that break wrapper scripts and tests. `timeout` propagates 128+signal rather than GNU's 124, so the exit status cannot distinguish "timed out" from "child died of SIGTERM"; anything that needs to tell them apart must own the timeout itself and report it structurally.

```text
  wrapper wants "did it time out?"
            │
            ├── busybox timeout 1 CMD      -> 143 (128+TERM)  \
            │                                137 (128+KILL)   > indistinguishable
            └── CMD killed by TERM itself  -> 143            /
            └── own the deadline in code   -> structured "timed_out": true
```

## Verified on dist/darwin-arm64/bin/busybox (busybox 1.39.0.git)

```
$ busybox timeout 1 busybox sleep 5 ; echo $?         -> 143   (128+SIGTERM)
$ busybox timeout --signal=KILL 0.3 sleep 5 ; echo $? -> 137   (128+SIGKILL)
$ busybox timeout --kill-after=1 --signal=KILL 0.3 sleep 5    -> long options work
$ busybox sleep 0.25                                  -> pauses ~250 ms, not 0
$ busybox sh -c 'type sleep'                          -> /bin/sleep (no builtin)
```

Config symbols in `build/darwin-arm64/.config` and `build/linux-arm64/.config`: `CONFIG_SLEEP=y`, `CONFIG_TIMEOUT=y`, `CONFIG_FEATURE_FANCY_SLEEP=y`. `CONFIG_ASH_SLEEP` is absent from both, so every `sleep` in a shell loop is a fork+exec.

## Consequences

- The symbol is `CONFIG_FEATURE_FANCY_SLEEP`, not `FLOAT_SLEEP`; that one gate provides multiple args, `s`/`m`/`h`/`d` suffixes and fractional seconds to both `sleep` and `timeout`. Turning it off silently makes `sleep 0.1` a no-op rather than an error.
- A test that asserts "timed out" by checking `$? == 124` never passes here; assert on elapsed milliseconds or on a wrapper's own status instead.
- `timeout` signals one process, not a group. Pair it with `setsid` (or kill the pgid yourself) when a child spawns descendants, and remember there is no subreaper on Darwin.
- `README.md` records the 124 difference as deferred on purpose (busybox is effectively `--preserve-status`), so do not "fix" it casually: changing it would alter an existing applet's documented behaviour.
