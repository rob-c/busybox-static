---
title: "Outline's C recall, measured against ast-grep: 52/52 and 24/24"
kind: "gotcha"
summary: "Outline now matches ast-grep's function set on run.c (52/52) and brief.c (24/24); the misses were multi-line signatures and functions returning a struct, plus a freed-name bug."
tags: [outline, ast-grep, patch-0022, measurement]
created: "2026-11-23T22:19:24.288Z"
updated: "2026-11-23T22:19:24.288Z"
---
`outline`'s C function detection now matches ast-grep's `function_definition` nodes on the files checked: `src/coreutils/run.c` 52/52 and `src/miscutils/brief.c` 24/24 (was 47/52 and 19/24). The ten misses were two shapes, not ten bugs.

```text
  static void pump(int fds[3], int arts[3], int nr,   ← signature continues
                     int feed_to, int feed_from,        for two more lines
                     ...
  static struct item *item_new(void)                  ← returns a struct
```

## The two shapes

- **A signature that continues on the next line.** `kind_of` classified one line at a time, so a line ending in `,` had no `)` and no `{`. Continuation lines are now joined — up to a bounded size — until the parentheses balance, and the definition is reported at the first line, which is where `peek --from-byte` should land.
- **A function that returns a struct.** `static struct item *item_new(void)` matched the `struct` keyword first and was reported as a type. A `(` after the type name now hands the line to the function test.

One more defect surfaced on the way: the joined buffer was freed while `name` still pointed into it, so the reported name came out empty (`1:function:0:`).

## Measuring against something that knows

The comparison that found these is `ast-grep run --lang c --kind function_definition --json=stream FILE | jq '.range.start.line+1'`, diffed against `outline`'s function lines. A heuristic can only be trusted for what has been counted, and counting against a real parser is what turned "two files look plausible" into a specific list.

Anchoring note: ast-grep points at the declaration's first line, `outline` at the line holding the name. For `static void FAST_FUNC\nfoo(...)` that differs by one line; both are defensible, and the name line is the more useful jump target.

`tests/new-applets.sh` section **O5** pins multi-line signatures, a struct-returning function and a plain one — 62 checks. Suites: `timeline-query` 42, `test.sh` 198, `agent-ops` 1299, `streams` 37, `plugin-reports` 26. Patch `0022` regenerated; `patchcheck` → `checked=22 bad=0`.
