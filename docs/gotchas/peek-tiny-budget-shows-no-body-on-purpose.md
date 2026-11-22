---
title: "`peek`'s tiny-budget \"no body\" is intentional — do not clamp it"
kind: "gotcha"
summary: "`peek --max-bytes 1` emitting no body with `next` at the same offset is intended (budget.zero.no.body); forcing a partial line breaks three reassembly checks."
tags: [peek, truncation, tests, patch-0006, gotcha]
created: "2026-11-22T17:29:36.583Z"
updated: "2026-11-22T17:29:36.583Z"
---
`peek --max-bytes N` with a budget too small for one line deliberately emits **no** body and returns `truncated:true` with `next` pointing at the same line start. That is not a bug to "fix" by forcing a partial line: `tests/agent-ops.sh` asserts it (`peek.budget.zero.no.body` ⇒ `--max-bytes 1` yields zero body lines), and the caller continues by raising the budget. Any clamp that guarantees progress breaks 3 reassembly checks and this one.

```text
  --max-bytes 1     shown_bytes 0   truncated true   next {"from_byte":0}   # no body
  --max-bytes 40    shown_bytes 40  truncated true   next {"from_byte":N}   # partial line ok
  --max-bytes 16384 shown_bytes …   truncated false  next null
```

## The trap

Showing "at least one character so `next` advances" looks like an obvious robustness fix and is wrong twice over:

- the reassembly tests (`peek.reassemble.n60.txt.*`) compare the union of consecutive pages against lines 1..60, so an extra partial line duplicates content and gaps appear (`got [1..11, 30..38, 57..60]`);
- `budget.zero.no.body` encodes the opposite promise — a tiny budget is a *probe*, not a read.

The loop risk lives on the caller's side: following `next` without increasing `--max-bytes` makes no progress by design.

## Related fix that did land

`log NOSUCH --format json` returned `{"code":"NOT_FOUND"}` with no `message`; BUSYBOX-CONTRACT.md §4 lists `message` among the fields the plugin renders, so it now reads `{"code":"NOT_FOUND","message":"run not found or stream missing"}`.

Suite: 1299 passed on darwin-arm64; `busybox patchcheck` -> checked=14 bad=0.
