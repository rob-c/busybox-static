---
title: "Compact timeline stamps; `json --set` reverted for data loss"
kind: "instruction"
summary: "`run -t` stamps are now `0.019841` / `1.213` / `13.22` (no leading zeros, 6/3/2 decimals); `json --set` was reverted because its serialiser dropped sibling members."
tags: [run, timeline, stamps, json, patch-0008]
created: "2026-11-24T02:53:07.804Z"
updated: "2026-11-24T02:53:07.804Z"
---
`run -t` now prints compact stamps: no leading zeros, and the fraction gets shorter as the seconds grow. `-n` still gives nine digits, and the JSON timeline still carries full microseconds, so exact values are never lost.

```text
  before                 after
  [00000.006182 out] a   [0.006182 out] a     <1 s    6 decimals
  [00001.213492 out] b   [1.213 out] b        1–9 s   3 decimals
  [00013.224961 out] c   [13.22 out] c        >=10 s  2 decimals
```

## Why the ladder, and what it costs

Fixed width made every line 17 characters of stamp before any text — a third of a model's view for a short line. The ladder trades resolution for width only where the resolution is already unimportant: within one magnitude the width is constant, so ordering inside a phase is preserved; across magnitudes the absolute offset in the JSON (`timeline[].us`) is the authority.

**Contract impact:** a client parsing the old fixed-width form must accept 2–6 fraction digits. The plugin's `timing.ts` regex expects exactly six and will stop summarising long runs until it is relaxed — that is a *text-shape* change the contract permits, but the plugin does parse this text, so it must be told.

## What was not delivered

`json --set` (guarded JSON writing) is **not** in this tree. A first attempt was written and reverted: the option bits were off by one (`S` is the 8th letter, not the 7th) and, more seriously, the serialiser lost the sibling members of the object it replaced — `{"a":{"b":1}}` came back as `{"a":{}}`. A writer that can silently drop data is worse than no writer. The pieces it needs and the order they must be built in:

1. a serialiser proven against a round-trip property over a fixture set (`parse → serialise → parse` must be equal before any file is written),
2. the path walker returning the *parent* plus the final segment, with tests for a missing parent, an array index and a scalar parent,
3. atomic replacement only after (1) and (2) pass, with `--dry-run` as the default during development.

Existing JSON reading is unaffected: `json -f … -g …`, `-k`, `-t`, `-n`, `-c` all behave as before (the revert restored the shipped `json.c` exactly).

## Verification

`tests/timeline-query.sh` section **Q6b** pins the three widths and the absence of leading zeros — 46 checks. Suites: `agent-ops-sweep` 1311, `test.sh` 198, `agent-ops` 1299, `streams` 37, `plugin-reports` 26, `new-applets` 69. Patch `0008` regenerated; `patchcheck` → `checked=22 bad=0`.
