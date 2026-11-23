---
title: "The next layer of agent tooling: finish the timeline channel, not the capture side"
kind: "architecture"
summary: "The capture side of timed streams is strong; retrieval is text-only (no --since, --match ignored on timeline, no structured events, no idle timeout, no marks). Twelve binary-side proposals in three waves."
tags: [analysis, timeline, agentic-tooling, proposal, pi-managed-tools]
created: "2026-11-23T11:32:49.839Z"
updated: "2026-11-23T11:32:49.839Z"
---
The binary and the plugin already make timing the primary channel between a model and the system: every bash call becomes `busybox run --timestamps --prune 20 --timeout (pi-1)`, and the model reads `[   0.019841 out] one` lines plus a one-line shape summary. The gaps are all on the *retrieval* side of that channel, not the capture side — the timeline is produced well and then re-parsed as text by the client.

```text
  bash call ──► busybox run -t ──► artifacts (stdout, stderr, meta)   CAPTURE: good
                      │                     │
                      ├─ view (bounded)     └─ log RUN --stream timeline   RETRIEVAL: text only
                      └─ JSON timeline[]        (--match ignored, no time window)
                                                      │
                                       plugin re-parses [ t out] in TypeScript
                                       (timing.ts TIMELINE_LINE) to summarise
```

## Measured gaps (each reproduced against 0.5.0)

| # | gap | evidence |
|---|---|---|
| 1 | `log --stream timeline` returns `content[].text` strings, not events | `log R2 --stream timeline --format json` → `[   0.014495 out] a` |
| 2 | ~~`--match` ignored on the timeline~~ **withdrawn: it works** | `log R1 --stream timeline --match bravo --context 0` → `lines:[[3,3]]`; the earlier "all 3 lines" was the default context of 3 |
| 3 | no time-addressed retrieval | `log R --since 0.05` → `unrecognized option '--since'` |
| 4 | `--brief` and `--timestamps` are exclusive | `run -t --brief both` ignores the reduction (ladder in `wrap.ts` drops timestamps for brief for this reason) |
| 5 | only a wall deadline, no idle/hang detection | `run --timeout` is the only deadline flag |
| 6 | no bounded sample for high-entropy floods | view is head+tail bytes; nothing yields "the 40 lines that matter" |
| 7 | no guest-side marks; phases must be read out of 300 lines | no `BUSYBOX_RUN_ID` in the child |
| 8 | no streaming output; JSON is one document at exit | `run --format json` emits nothing until the child ends |
| 9 | retrieval can only be post-hoc | plugin's `truncationHint` tells the model to re-call `log --match` |
| 10 | `--caps .features` does not advertise brief/pty/timeline/error-ids | `features:[gnu-long-opts,peek,replace,waitfor,run,log,doctor,json]` |
| 11 | no unified-diff apply with preconditions | `replace` is single-file literal; agents emit diffs |
| 12 | no symbol navigation | `peek` is line- and byte-addressed only |

## Wave 1 — finish the timeline channel (highest value, smallest risk)

1. **Structured timeline retrieval.** `log R --stream timeline --format json` gains `events:[{us,stream,text,n}]` *alongside* the existing `content[]`, and honours `--match`/`--lines` for that stream. Additive keys only, so the plugin keeps working while `timing.ts` stops re-parsing text.
2. **Time windows.** `--since 1.2 --until 2.4` (seconds, fractional) and `--around-gap 0.5` (the N largest silences) on both `log` and `run --format json`. This is the query the model actually asks after reading a summary: "what happened between 6.1 s and 8.4 s".
3. **`log --summary`.** The deterministic digest the plugin builds in TypeScript today: total, lines, first output, first stderr, longest gap, error lines, exit code — one object, `{"schema":1,...}`. Any client gets the same sentence; the plugin can delete `summarizeTiming`.
4. **Brief on top of timing.** Make `--brief` work with `--timestamps` (reduce per stream, keep the `[ t out]` prefixes), so the one mode built for 40 000-line floods stops dropping the timing it needs.

## Wave 2 — instrument the guest

5. **`run --idle-timeout SECS`** → `code:"IDLE_TIMEOUT"`, exit 3. A hung build and a slow build look identical today; only wall-clock total can tell them apart, and it cannot.
6. **`mark` applet + `BUSYBOX_RUN_ID`/`BUSYBOX_RUN_START` in the child.** `mark phase:build` appends a named event to the run's timeline (monotonic offset from the run start), so scripts self-instrument and the model reads `phase:build 0.42s → 12.8s` instead of inferring phases from prose.
7. **`run --jsonl`.** One JSON object per event (`{"t":1234,"s":"out","line":"…"}`), flushed as produced, for harnesses that want to stream rather than wait for exit.
8. **`log --sample N`** (and `run --sample`): first N, an explicit omission marker, last N — a bounded, deterministic digest for output whose lines are all distinct and therefore immune to `brief`.

## Wave 3 — navigation and change

9. **`patchapply`** — unified-diff apply with `--dry-run`, per-file `--sha256` preconditions from `peek`'s `version`, atomic temp+rename, JSON `results[]`. Models emit diffs; `replace` cannot consume one.
10. **`outline PATH`** — definitions (function/class/heading/rule anchors) with `line`, `byte` offset and `version`, so `peek --from-byte` jumps straight to a body. Heuristic per language, no parsers, bounded.
11. **`run --replay`/`log --diff --timeline`** — compare two runs by timeline shape (line counts per second, gaps, first stderr), which answers "why is this slower than before" without a second read.
12. **`--caps` feature flags** for `brief`, `pty`, `timeline`, `error-ids`, `jsonl`, so the plugin can feature-detect instead of assuming one build's shape.

## Deliberately not proposed

- ptrace/perf sampling, `/proc`-based child accounting, `LD_PRELOAD` shims: all violate the cross-platform rule this build is built on.
- ANSI screen reconstruction from pty output: `--pty-split` plus `brief` already gives the model the signal it needs.
- An in-binary LSP or full parser: `outline` heuristics plus `peek` cover navigation at a fraction of the risk.

## Why binary-side beats plugin-side

Every proposal lands in the binary, so it serves `sh` scripts, `check`, `bench`, `snapshot` and any client — not just pi. The plugin's job then shrinks to argv building and rendering, the seam whose failure modes (salvage paths, shape assumptions, `--stream both` splitting, timeline regexes) are exactly what `BUSYBOX-CONTRACT.md` exists to pin down.
