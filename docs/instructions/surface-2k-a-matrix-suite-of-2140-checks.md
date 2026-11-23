---
title: "surface-2k: 2140 generated checks, and four assertion bugs of my own"
kind: "instruction"
summary: "`tests/surface-2k.sh` generates 2140 checks in twelve matrices over peek/replace/brief/run/log/patchapply/outline; four wrong assumptions were in the tests, not the binary."
tags: [tests, matrix, surface, patch-0022]
created: "2026-11-23T22:56:36.497Z"
updated: "2026-11-23T22:56:36.497Z"
---
`tests/surface-2k.sh` runs **2140 generated checks** (target was 2000) across the agent-facing applets, built as twelve matrices rather than 2000 hand-written cases. Runtime is about two minutes.

```text
  A peek 120      B replace 100     C brief 200      D run+summary 200
  E timeline 20   F sample 60       G marks 60       H jsonl 60
  I patchapply 200  J outline 200   K error ids 80   L exit codes 40
  M flags 60      N json validity 60  O help/caps 20  P regressions 30
  Q deadlines/pty 40  R peek --request 80  S replace --request 60
  T run inputs 100   U snapshot/bench/doctor 30    V brief invariants 30
  W peek budgets 235
```

## Four assertion bugs the matrix exposed — in the *tests*

Writing 2000 checks found nothing new in the binary and four wrong assumptions in the assertions, each of which would have looked like a product bug:

- **`--summary` counts timeline records, not lines.** A run that prints `n` lines to stdout and `n` to stderr reports `lines: 2n`, `stderr_lines: n`.
- **`--stream timeline` needs a run created with `-t`.** Without it the artifact does not exist and the answer is `NOT_FOUND` — the test created plain runs and blamed the binary.
- **The text renderer numbers its lines.** `log --stream timeline` prints `1 | [ 0.015 out] a`, so `grep '^\['` matches nothing; the pattern has to be `(out|err)\] `.
- **`grep -c tty` also matches the summary's stream labels**, so a pty check that looked for the child's line counted two. `^tty$` is the honest pattern.

## What it deliberately does not do

It is breadth, not depth: each check is one property (exit status, a JSON field, a count), so a shape regression is caught but a subtle value bug may not be. The focused suites remain the place for that — `agent-ops` 1299, `plugin-reports` 26, `timeline-query` 42, `new-applets` 69, `streams` 37, `reaper` 50, `timeout-resilience` 50 + matrix 200.

Run it as a background job (`(nohup ./tests/surface-2k.sh … > log 2>&1 &)`): at ~2 minutes it exceeds the harness's default per-call deadline.
