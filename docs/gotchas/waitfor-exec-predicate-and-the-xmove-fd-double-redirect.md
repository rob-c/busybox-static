---
title: "`waitfor --exec CMD` and the two-xmove_fd redirect trap"
kind: "gotcha"
summary: "`waitfor --exec CMD` polls until CMD exits 0; redirecting the child needs two dup2 from one open fd — two xmove_fd calls fail with 'can't duplicate file descriptor'."
tags: [waitfor, exec, xmove_fd, dup2, patch-0006]
created: "2026-11-22T15:19:50.905Z"
updated: "2026-11-22T15:19:50.905Z"
---
`busybox waitfor --exec CMD` polls until CMD exits 0, so readiness can be any shell test rather than a single path, socket or URL. Sixth `kind` in `waitfor`, shipped in `patches/0006-agent-ops-core.patch`.

```text
  --glob ─► kind 4 ─┐
  --exec ─► kind 5 ─┴─► poll loop ─► fork → sh -c CMD (stdout/stderr → /dev/null)
                                       └─ ready iff WIFEXITED && exit == 0
```

```
$ waitfor --exec 'test -f /tmp/wf2-ready' -T 1
ready=false kind=exec target=test -f /tmp/wf2-ready attempts=8 elapsed_ms=1021 code=TIMEOUT   # exit 3

$ touch /tmp/wf2-ready
$ waitfor --exec 'test -f /tmp/wf2-ready' -T 5 --format json
{"schema":1,"ready":true,"kind":"exec","target":"test -f /tmp/wf2-ready","attempts":1,"elapsed_ms":21}
```

## The bug that cost a build

Redirecting the child to `/dev/null` with **two `xmove_fd()` calls** fails: the first call closes the source fd, so the second reports `can't duplicate file descriptor: Bad file descriptor` once per poll — hundreds of lines of noise, and the poll never gets a usable exit status. Use `dup2(nul, 1); dup2(nul, 2); if (nul > 2) close(nul);` from the single opened fd.

## Behaviour

- CMD runs via `/bin/sh -c`, so quoting belongs to the caller; stdout and stderr go to `/dev/null` and are not captured.
- Any non-zero exit, signal death or `fork` failure counts as "not ready" — the loop keeps polling until the deadline and then returns `code=TIMEOUT` with exit 3, matching `--glob`.
- Like the other predicates it participates in the "exactly one of" guard, so `--exec` cannot be combined with `--file`.

Suite after this change: 1299 passed on darwin-arm64; `busybox patchcheck` → checked=14 bad=0.
