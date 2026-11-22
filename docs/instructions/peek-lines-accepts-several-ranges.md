---
title: "`peek --lines` accepts several ranges (patch 0006)"
kind: "instruction"
summary: "`busybox peek -l 2:3,10:11` accepts comma-separated ranges that fill the same ranges[] array --around uses, so the `--` separators, byte budget and JSON `lines` pairs are unchanged."
tags: [peek, lines, patch-0006, section-14-1, agent-features]
created: "2026-11-22T15:28:01.903Z"
updated: "2026-11-22T15:28:01.903Z"
---
`busybox peek --lines` now takes several ranges joined by commas — `-l 2:3,10:11` — closing the AGENT-FEATURES §14.1 item that noted the merged-window machinery already existed for `--around`. Carried in `patches/0006-agent-ops-core.patch`.

```text
  -l 5:9      ─┐
  -l 7        ─┼─► split on ',' ─► ranges[MAX_WINDOWS] ─► same renderer as --around
  -l 2:3,10:11─┘        └─ "5:9" without a colon part, "40:" means to EOF
```

```
$ peek -l 2:3,10:11 n.txt
n.txt lines=2-3,10-11 version=sha256:b76ae83c…
2 | 2
3 | 3
--
10 | 10
11 | 11
shown_bytes=28 truncated=false

$ peek -l 2:3,10:11 --format json n.txt
{"schema":1,"results":[{"lines":[[2,3],[10,11]],"content":[{"n":2,…},{…}],…}]}

$ peek -l 99 n.txt
peek: n.txt: NOT_FOUND: line range 99 is outside 1:20      # exit 1
```

## Details

- The comma split fills the same `ranges[]` array `--around` uses, so the `--` separator between non-adjacent windows, the byte budget, `truncated` and `next` all keep working unchanged. Empty fields (`-l 2:3,`) are skipped; a spec with no usable range is `INVALID_ARGUMENT`.
- Out-of-file ranges are still `NOT_FOUND` with the full `--lines` string quoted in the message, and exit 1.
- The JSON `lines` member is an array of `[first,last]` pairs — anything that expects a single pair for the one-range case still sees `[[5,9]]`, so the shape stays consistent.

Suite after the change: 1299 passed on darwin-arm64; `busybox patchcheck` → checked=14 bad=0.
