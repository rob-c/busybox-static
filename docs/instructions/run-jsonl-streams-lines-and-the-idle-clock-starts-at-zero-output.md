---
title: "`run --jsonl` streams objects; the idle clock had to start before any output"
kind: "instruction"
summary: "`run --jsonl` emits flushed per-line objects plus an exit event and suppresses the human summary; `--idle-timeout` now counts silence from the first poll, not from the first byte."
tags: [run, jsonl, streaming, idle-timeout, patch-0008]
created: "2026-11-23T17:30:30.291Z"
updated: "2026-11-23T17:30:30.291Z"
---
`run --jsonl` emits one flushed JSON object per line as the guest produces it, ending with an exit event, so a harness can watch a long command instead of waiting for a document at exit. The same code path also fixed `--idle-timeout` for a guest that never writes at all.

```text
  run --jsonl -- sh -c 'echo one; echo bad >&2; sleep 0.1; echo two'
  {"t":0,"s":"out","line":"one"}
  {"t":90000,"s":"err","line":"bad"}
  {"t":230093,"s":"out","line":"two"}
  {"event":"exit","run":"R7","exit_code":0,"timed_out":false,"cancelled":false,"idle":false,"duration_ms":252}
```

## Rules that make NDJSON usable

- **Reassemble lines across `read()` boundaries.** The pump hands whole chunks; a chunk can end mid-line, so each stream keeps a partial-line buffer and only emits on a newline (or at end of stream).
- **The clock starts at the first event**, not at fork: the first attempt set the base in one of two fork sites and every `t` came out `0`.
- **Suppress the human summary.** With `--jsonl` the normal `run=R… exit_code=…` block and the `--- stdout ---` view are skipped, or a line-oriented consumer breaks on the first non-JSON line.
- **Flush per object.** Without `fflush` the point of streaming is lost behind stdio buffering.

## The idle bug this exposed

`--idle-timeout` only started counting once the guest had written something (`last_data && …`), so `run --idle-timeout 1 -- sleep 9` ran the full nine seconds and exited 0 — the exact case the flag exists for. The silence clock now initialises on the first poll: the same command exits 3 after ~1 s.

Pinned by `tests/timeline-query.sh` Q7 (seven checks: count, first `t=0`, stderr tag, monotone `t`, exit event, all lines valid JSON via `busybox json -f`, no summary line). Suite total 42 checks; alongside: `test.sh` 198, `agent-ops` 1299, `streams` 37, `plugin-reports` 26. Patch `0008` regenerated and reverse-checked; `patchcheck` → `checked=21 bad=0`.
