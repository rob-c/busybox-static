---
title: "`waitfor --glob PATTERN` predicate (patch 0006)"
kind: "instruction"
summary: "`busybox waitfor --glob PATTERN` polls glob(3) until something matches; it is kind 4 beside file/tcp/unix/http, keeps exit 3 + code=TIMEOUT, and ships in patch 0006."
tags: [waitfor, glob, patch-0006, section-14-1, agent-features]
created: "2026-11-22T15:15:31.985Z"
updated: "2026-11-22T15:15:31.985Z"
---
`busybox waitfor --glob PATTERN` polls until a path matching PATTERN exists — the "readiness is application-defined" gap in AGENT-FEATURES §14.1, without inotify or kqueue. Carried in `patches/0006-agent-ops-core.patch`.

```text
  --file ─┐
  --tcp  ─┤
  --unix ─┼─► kind 0..4 ─► poll loop (deadline, interval, --format json)
  --http ─┤                  └─ glob(3): ready when rc==0 && gl_pathc>0
  --glob ─┘
```

```
$ waitfor --glob '/tmp/wf/ready*' -T 1
ready=false kind=glob target=/tmp/wf/ready* attempts=9 elapsed_ms=999 code=TIMEOUT   # exit 3

$ touch wf/ready1
$ waitfor --glob '/tmp/wf/ready*' -T 5 --format json
{"schema":1,"ready":true,"kind":"glob","target":"/tmp/wf/ready*","attempts":1,"elapsed_ms":0}
```

## How it fits

- `--glob` is a fifth `kind` (4) beside `--file`/`--tcp`/`--unix`/`--http`, so it reuses the existing deadline, poll interval and JSON writer; the "exactly one of" guard counts it too.
- One `glob(3)` call per attempt, `globfree()` every time so the loop cannot leak. Timeout keeps the applet's contract: `code=TIMEOUT`, exit **3**.
- `#include <glob.h>` must be added explicitly — `libbb.h` does not pull it in.

## Regenerating

`waitfor.c` ships in `patches/0006-agent-ops-core.patch` with `libbb/appletlib.c`, `peek.c`, `why.c` and the `json_read` pair: `git diff HEAD -- libbb/appletlib.c coreutils/peek.c miscutils/waitfor.c libbb/json_read.c include/json_read.h miscutils/why.c`. Suite after this change: 1299 passed, `patchcheck` → checked=14 bad=0.
