---
title: "`run --prune N` keeps only the newest N runs (patch 0008)"
kind: "instruction"
summary: "`busybox run --prune N` unlinks stdout/stderr/meta and rmdirs every run beyond the newest N, sorted numerically so R10 outranks R9; pruning runs after the current run finishes."
tags: [run, prune, patch-0008, section-14-1, agent-features]
created: "2026-11-22T16:27:50.456Z"
updated: "2026-11-22T16:27:50.456Z"
---
`busybox run --prune N` deletes all but the newest N run directories under the artifact root, so run artifacts cannot grow without bound. AGENT-FEATURES §14.1; ships in `patches/0008-agent-ops-run.patch`.

```text
  run --prune 2 -- true
        ├─ run completes and writes its own artifacts
        ├─ list R<n> dirs, sort NUMERICALLY descending
        └─ for each beyond N: unlink stdout, stderr, meta → rmdir
```

```
$ for i in 1 2 3 4 5; do run -- true; done          # R1..R5
$ run --prune 2 -- true
pruned=4 keep=2
$ ls $TMPDIR/busybox-run
R5 R6
```

## Why numeric sorting matters

Run ids are `R<n>` strings, so a lexical descending sort puts `R9` above `R10` and the wrong runs get deleted past id 9. `prune_runs()` parses the number after the `R` and insertion-sorts numerically descending.

## Behaviour

- Pruning happens **after** the current run finishes, so the run being reported is never a candidate.
- Each directory is removed the same way it was built: `unlink` `stdout`, `stderr`, `meta`, then `rmdir`. A `rmdir` failure (extra file in the directory) is not fatal and is not counted.
- `--prune 0` is treated as `--prune 1`, so the current run always survives.
- The text output gains `pruned=<count> keep=<N>`; JSON output is unchanged (no new keys), which keeps existing parsers safe.

Suite after the change: 1299 passed on darwin-arm64; `busybox patchcheck` -> checked=14 bad=0.
