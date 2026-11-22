---
title: "50-check deadline suite: guests that trap, ignore or outlive signals"
kind: "instruction"
summary: "`tests/timeout-resilience.sh` has 50 checks for guests that trap/ignore signals or leave grandchildren; the ps orphan scan must be verified against a leaked process or it passes blindly."
tags: [tests, timeout, run, sh, signals, patch-0008]
created: "2026-11-22T18:09:42.561Z"
updated: "2026-11-22T18:09:42.561Z"
---
`tests/timeout-resilience.sh` holds 50 checks that `run --timeout` and `sh --timeout` still exit 3 on time when the guest catches, ignores or outlives signals. Run it with the built binary: `./tests/timeout-resilience.sh dist/darwin-arm64/bin/busybox`.

```text
  A  baseline deadline                          5 checks
  B  guest traps TERM and keeps running         6
  B2 guest traps TERM and exits 0               4
  B3 guest ignores TERM+INT+HUP                 4
  C  grandchild ignores TERM                    4
  C2 --kill-after 0.2                           3
  D  sh --timeout (cmd, script, usage, rc)      8
  E  sub-second and repeated deadlines          5
  F  --brief / --brief-json inside a deadline   5
  G  five consecutive timeouts                  2
  H  exit-code taxonomy (7, 3, 1, 0s)           4
```

## Making the orphan checks honest

Two traps cost real time here:

- **The harness matches itself.** `ps -A -o command=` shows the test's own `bash -c` line, which contains the marker string, so every "no orphan" check failed at first. The marker is now built with `printf 'tb%s' 1` so the literal never appears in the harness command line, and `alive()`/`sweep()` filter out `awk`, `grep`, `ps -A` and the script path.
- **A blind scan passes by accident.** Before trusting the check, run it against a deliberately leaked `sh -c 'echo <marker>; sleep 5' &` — it must report `true`. It does; without that verification a broken filter looks like a passing test.

## What the run turned up

`run --timeout 0` was a usage error (exit 2); it now means "the deadline has already passed" and reports `timed_out:true` with exit 3, so an immediate timeout is expressible. Everything else already held: a guest that ignores `TERM` is escalated to `SIGKILL` after `--kill-after` (default 2 s, and the whole containment takes about `timeout + grace`), and the wrapper never leaks 124 or 128+N.

Results: 50 passed, 0 failed, 0 skipped on darwin-arm64; `agent-ops` 1299 passed; `test.sh` 198 passed.
