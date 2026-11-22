---
title: "`brief`'s budget can expire inside a group: the remainder is merged, not dropped"
kind: "discovery"
summary: "A budget that expires between one group's samples must count the unprinted remainder as merged, not dropped; the old loop double-counted and broke `in == shown + merged + dropped`."
tags: [brief, invariant, budget, samples, patch-0014, testing]
created: "2026-11-22T16:46:28.375Z"
updated: "2026-11-22T16:46:28.375Z"
---
In `brief`'s emit loop the byte budget can run out *between* the samples of one group, and the bookkeeping must then split that group's count: the occurrences already printed stay `shown_lines`, the rest of the same group is `merged`, and only the groups after it are `dropped`. The loop this replaced added the whole count to `dropped_lines`, so `lines_in != lines_shown + lines_merged + dropped_lines` — the applet's headline invariant — could be broken by `-a` plus a tight `-B`.

```text
  group A: count=3, samples allowed=8, budget N bytes
  k=0  "3x x1"   fits    -> shown_lines=1, emitted=1
  k=1  "+ x2"    does not fit -> budget spent
        correct: merged += 3-1 = 2   dropped  += 0       3 = 1 + 2 + 0
        old:     merged += 0         dropped  += 3       3 != 1 + 0 + 3
  groups after A -> dropped, one count each
```

## The negative control

Three records that share a digit-masked key, with two samples allowed and a 6-byte budget:

```sh
printf 'x1\nx2\nx3\n' > var.txt
busybox brief -s -a 8 -B 6 var.txt
```

* correct: `shown_lines=1 merged=2 dropped_lines=0`
* the old loop: `shown_lines=1 merged=0 dropped_lines=3`

Nothing in the 690-check suite caught it, because every budget case used a single sample per group (`-a` was tested with `-s`, and `-B` was tested without `-a`); the two properties are only dangerous in combination.

## Why the rule generalises

Any loop that emits part of a group and then abandons it has this shape, and only the invariant notices. Write the accounting as three buckets and assert `in == shown + merged + dropped` after every emission point. `tests/brief.sh` §32 pins this case; the 21-option matrix in §24 asserts the invariant across `-c`/`-t`/`-m`/`-q` too.

## Related

The same question decides `-m`: a group below the threshold was never shown, so its lines are `dropped`, not `merged`. `-t` changes only the order, never the counts.
