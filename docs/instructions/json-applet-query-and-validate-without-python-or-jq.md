---
title: "`json` applet: query and validate JSON without python or jq (patch 0010)"
kind: "instruction"
summary: "`busybox json -f FILE -g .a.b[2] -k|-t|-n|-c --format json` queries JSON via libbb/json_read.c; watch the xmalloc_open_read_close size-limit trap and the json_main_main symbol name."
tags: [json, applet, patch-0010, json_read, agent-features]
created: "2026-11-22T14:23:59.477Z"
updated: "2026-11-22T14:23:59.477Z"
---
`busybox json` answers one question about a JSON document from the shell without Python or jq: validate it, list keys, or print the value/type/length at a path. It ships as `patches/0010-agent-ops-json.patch` and reuses `libbb/json_read.c`, so it adds no parser of its own.

```text
  json -f d.json [-c | -g .a.b[2].c [-k|-t|-n]]
        │
        ├─ xmalloc_open_read_close()   size arg = UPPER BOUND, pass (size_t)-1
        ├─ json_parse()                libbb/json_read.c  → INVALID_JSON on failure
        └─ walk(".a.b[2]")             json_get / json_at  → NOT_FOUND on a gap
```

```
$ json -f d.json -c --format json        {"schema":1,"status":"ok","type":"object"}
$ json -f d.json -g .a.b[2].c            hi
$ json -f d.json -g .a.b -n              3
$ json -f d.json -k                      a n t
$ json -f d.json -g .a.b[1] -t           number
$ json -f d.json -g .nope --format json  {"code":"NOT_FOUND","path":".nope",…}  rc 1
$ echo '{bad' | json --format json       {"code":"INVALID_JSON",…}             rc 1
```

## Gotchas that cost a build each

- **`xmalloc_open_read_close(path, &sz)` treats `sz` as an *upper bound*, not an out-parameter.** `size_t len = 0` reads zero bytes, and the parser then says `at byte 0: unexpected end of input` for a good file. Start at `(size_t)-1`, then `strlen(buf)`.
- **Name the entry point `json_main_main`.** The applet is already `json`, so `APPLET_NOEXEC(json, …)` wants `<name>_main`; a mismatch is a *link* error (`Undefined symbols: "_json_main_main"`).
- **`CONFIG_JSON=y` belongs in both `EXTRA_CONFIG` blocks** in `build.sh` (Linux and Darwin), and since `src/` is a separate busybox checkout, make the patch with `git diff HEAD -- coreutils/json.c` inside `src/` — plain `git diff` is empty once the file is staged.

Path grammar is `.a.b[2]`; no `-g` (or `.`) targets the root. Both failure modes stay inside the contract's 0/1/2/3 exit range, and `tests/agent-ops.sh` remains 1299 passing on darwin-arm64.
