---
title: "Real input found seven defects in outline and patchapply"
kind: "gotcha"
summary: "Seven defects fixture tests missed: macro/keyword/member false positives, invisible `export class`, a shared hunk buffer, no preflight, and writing freed memory."
tags: [outline, patchapply, patch-0022, testing, defects]
created: "2026-11-23T21:38:05.558Z"
updated: "2026-11-23T21:38:05.558Z"
---
`outline` and `patchapply` had seven defects that fixture tests never exposed: macro calls and `for` loops reported as functions, indented struct members reported as types, `export class` invisible, Markdown headings skipped, a two-file `git diff` refused, and a batch that half-applied.

## outline

```text
  //applet:IF_BRIEF(APPLET_NOEXEC(...))  →  was 'function:APPLET_NOEXEC'
  for (;;) { …                          →  was 'function:for'
  \tstruct sample smp[N];               →  was 'struct:sample' (a member, not a type)
  export class C {                      →  was invisible
  # Heading                             →  was skipped as a preprocessor line
```

The rules that fix it: reject ALL_CAPS names and a list of C keywords as function names; a `struct`/`union` is a definition only at column 0; strip declaration qualifiers (`export`, `static`, `public`, …) before matching the kind; `#` is a preprocessor line only when no space follows it.

## patchapply

```text
  two-file git diff   →  HUNK_MISMATCH, after the first file had been written
  +++ /dev/null       →  path lost, so a deletion could not be performed
```

Three causes, worst first:

1. **All hunks shared one parse buffer.** `h->body` pointed into a single `buf` that the next hunk realloc'd, so file A's hunk compared file B's bytes. Each hunk now owns its body.
2. **No preflight.** Verification and writing ran in one pass, so file 1 landed before file 2 failed. Now phase 1 verifies every file and keeps the computed bytes; phase 3 writes only if all verified, and an aborted batch prints `patchapply: aborted, nothing written`.
3. **Ownership.** Phase 1 freed the output that phase 3 then wrote — the files came out as binary garbage (`x=��o`). The buffer now survives until phase 3 frees it.

## Why the fixtures missed it

Hand-written patches are one file, one hunk, ASCII identifiers. The applet's own usage text promises "every hunk is checked before it is written; one mismatch aborts the whole patch" — that promise was false until a mixed good/bad patch was measured.

`tests/new-applets.sh` now carries a real `diff --git` block, a two-file patch, a mixed good/bad patch, a deletion, and a C fixture with a macro call, a member declaration and an `export class` — 53 checks. Suites: `timeline-query` 42, `test.sh` 198, `agent-ops` 1299, `streams` 37, `plugin-reports` 26. Patch `0022` regenerated; `patchcheck` → `checked=22 bad=0`.
