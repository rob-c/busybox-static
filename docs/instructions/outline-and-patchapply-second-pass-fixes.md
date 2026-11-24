---
title: "outline and patchapply: brace-on-next-line, prototypes, creation, repeatable -c"
kind: "instruction"
summary: "`outline` now detects C definitions with the brace on the next line and skips prototypes; `patchapply` creates files from `--- /dev/null` and takes repeatable `--sha256` preconditions."
tags: [outline, patchapply, patch-0022, defects]
created: "2026-11-23T21:23:11.480Z"
updated: "2026-11-23T21:23:11.480Z"
---
The first version of `outline` and `patchapply` shipped with three real gaps, now closed: `outline` missed every C definition whose brace sits on the next line and never skipped prototypes; `patchapply` could not create a file and accepted only one `--sha256` precondition.

```text
  int add(int a)        →  1:function:0:add      (was: invisible)
  {                     →
  int proto(int a);     →  skipped               (was: reported as a function)
  --- /dev/null
  +++ b/new.txt         →  new.txt created, +2 -0 (was: NOT_FOUND, nothing written)
  -c a=… -c b=…         →  both checked first     (was: last one won)
```

## Why each slipped through

- **Brace on the next line.** The detector required `{` on the same line, which is the *less* common C style. The fix accepts a line that ends in `)` and contains no `;`, and treats the next line's brace as the body.
- **Prototypes.** Without that rule `int proto(int a);` looks exactly like a definition; the `;` test is what separates them, and it has to run before the brace search falls back.
- **Creation.** `is_new` was derived from the `+++` line being `/dev/null` — that is a *deletion*. The old side (`--- /dev/null`) is the creation marker, and the reader then has to accept an empty file as a valid base instead of `NOT_FOUND`.
- **Repeatable `-c`.** `getopt32long` keeps only the last value of an option, so preconditions are peeled off argv into a list (the same technique as `--env` and `log --diff`).

## Tests that pin them

`tests/new-applets.sh` sections **N** (create, `-c` twice, second stale refuses) and **O2** (`function:add` present, `proto` absent) — 38 checks total. Alongside: `timeline-query` 42, `test.sh` 198, `agent-ops` 1299, `streams` 37, `plugin-reports` 26. Patch `0022` regenerated and reverse-checked; `patchcheck` → `checked=22 bad=0`.
