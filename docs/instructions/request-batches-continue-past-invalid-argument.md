---
title: "`replace --request` continues past INVALID_ARGUMENT; `waitfor --timeout 0` is one attempt"
kind: "instruction"
summary: "`replace --request` continues past INVALID_ARGUMENT but stops on STALE_INPUT/NOT_FOUND (with a skipped count); `waitfor --timeout 0` now means one attempt instead of a usage error."
tags: [replace, request, waitfor, patch-0007, patch-0006, busybox-contract]
created: "2026-11-22T17:22:42.489Z"
updated: "2026-11-22T17:22:42.489Z"
---
`replace --request` treats `INVALID_ARGUMENT` as a per-entry rejection and keeps going, while `STALE_INPUT` and `NOT_FOUND` abort the batch (and report how many edits were not attempted). `waitfor --timeout 0` performs exactly one attempt. Both align the build with BUSYBOX-CONTRACT.md §5–6; they ship in `patches/0007-agent-ops-edit.patch` and `patches/0006-agent-ops-core.patch`.

```text
  --request [{ok}, {edit has no "old"}, {ok}]
        ├─ entry 1  ok
        ├─ entry 2  INVALID_ARGUMENT     (this entry only)
        └─ entry 3  ok                   → three results, exit 1

  --request [{ok}, {path missing}]
        ├─ entry 1  ok
        ├─ entry 2  NOT_FOUND            → break
        └─ stderr: "1 edit(s) not attempted after an earlier failure"
```

## Why the split

A malformed entry says nothing about the file, so the remaining edits are still meaningful and the plugin's batch summary can "check each result". A stale or missing file invalidates every later edit to it — continuing would apply changes against content the caller never saw — so the loop stops and says so on stderr, keeping stdout valid JSON.

## waitfor --timeout 0

`strtod` accepted only `> 0`, so a single-shot check was impossible. The deadline equals the start time, so the loop performs one attempt and then breaks: `{"ready":true,...}` exit 0, or `{"ready":false,"code":"TIMEOUT"}` exit 3. Interval bounds and every predicate are unchanged.

Suite after the change: 1299 passed on darwin-arm64; `busybox patchcheck` -> checked=14 bad=0.
