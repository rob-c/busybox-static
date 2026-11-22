---
title: "`log --stream both --format json` must emit two objects, not text"
kind: "gotcha"
summary: "`log --stream both --format json` printed text inside the results array (unparseable); pass `json` through to dump_stream so each stream prints its own object."
tags: [log, json, patch-0008, busybox-contract, stream-both]
created: "2026-11-22T17:10:13.956Z"
updated: "2026-11-22T17:10:13.956Z"
---
`busybox log --stream both --format json` returns `{"schema":1,"results":[{…},{…}]}` with one object per stream, exactly like a single-stream answer. It used to return text inside the array, which no JSON parser accepts. Fixed in `patches/0008-agent-ops-run.patch`.

```text
  log R43 --stream both --format json
     ├─ log_main: fputs {"schema":1,"results":[        ← always JSON envelope
     ├─ dump_stream(stdout, …, json)  -> {"stream":"stdout",…}
     ├─ putchar(',')
     └─ dump_stream(stderr, …, json)  -> {"stream":"stderr",…}   then ]}
```

## Cause

`log_main` called `dump_stream(..., json && !both)`, so when `--stream both` was active the renderer received `json = 0` and produced text lines (`stdout lines=1-1`) while the surrounding `{"schema":1,"results":[` / `]}` was still emitted. Passing `json` unchanged makes each stream print its own JSON object, joined by a comma.

## Checking a contract against a real build

BUSYBOX-CONTRACT.md says which invocations the plugin issues; each one must be run and parsed with `jq` against the built binary, not only the ones the suite covers. This defect survived because no test asked for `--stream both` and `--format json` together. The three defects the contract named (double-escaped `run` view, spawn failure reported as 127, empty message on a 0-match `replace`) are fixed and re-verified.

Suite after the change: 1299 passed on darwin-arm64; `busybox patchcheck` -> checked=14 bad=0.
