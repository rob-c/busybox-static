---
title: "`peek --diff HASH` reports whether a file changed (patch 0006)"
kind: "instruction"
summary: "`busybox peek --diff HASH FILE` re-hashes and exits 0 (unchanged) or 1 (changed); it must run before the request envelope, or the JSON ends up double-wrapped."
tags: [peek, diff, patch-0006, section-14-1, agent-features]
created: "2026-11-22T15:49:38.579Z"
updated: "2026-11-22T15:49:38.579Z"
---
`busybox peek --diff HASH FILE` answers whether a file still hashes to a previously reported version. It re-hashes the file, compares against the `version=sha256:…` a prior `peek` printed, and exits 0 when unchanged, 1 when changed. Ships in `patches/0006-agent-ops-core.patch`.

```text
  peek f                       … version=sha256:edeaaff3…      <- remember this
  peek --diff sha256:edeaaff3… f
        ├─ equal   -> f changed=false version=…   exit 0
        └─ differ  -> f changed=true  version=…   exit 1
```

```
$ peek --diff sha256:edeaaff3… --format json p.txt
{"schema":1,"path":"p.txt","status":"ok","changed":false,"version":"sha256:edeaaff3…"}

$ peek --diff sha256:edeaaff3… missing.txt
peek: missing.txt: No such file or directory      # exit 1
```

## Why the check runs before the request envelope

`peek` normally prints `{"schema":1,"results":[ … ]}` around each request. Answering `--diff` from inside the per-request code emits a second envelope, so the output becomes `{"schema":1,"results":[{"schema":1,…` and no JSON parser accepts it. The check therefore sits in `peek_main`, before the request loop, and calls `fflush_stdout_and_exit()` so no trailing members follow. A `sha256:` prefix on the argument is optional.

## Contract notes

- Exit 0 / 1 only, consistent with `log --diff` and `snapshot --diff`.
- Single-file mode only; with `--request` the flag is ignored.
- `json_member_str("path", …)` already writes the `"path":` key — printing `,"path":` in front of it yields `"path":"path":"p.txt"`, the malformed-JSON symptom to look for.

Suite after the change: 1299 passed on darwin-arm64; `busybox patchcheck` -> checked=14 bad=0.
