---
title: "Outline: comments are prose; Go, Rust, Java and shell already parse"
kind: "instruction"
summary: "Outline stops at a trailing `#`/`//` comment (a comment ending in `)` was a function), and Go/Rust/Java/shell definitions already work; shell recall is 137 vs 120 by grep, recorded as best-effort."
tags: [outline, languages, patch-0022, measurement]
created: "2026-11-23T22:24:56.990Z"
updated: "2026-11-23T22:24:56.990Z"
---
`outline` now ends a line's *code* at a trailing `#` or `//` comment before classifying it, and the other languages it was assumed not to support turn out to work: Go, Rust, Java and shell definitions are detected by the same qualifier-strip and function-shape rules as C.

```text
  cp -R "$A" "$OUT"   # keep the symlink farm (relative links still resolve)
      before: 23:function:1098:farm        ← a comment read as code
      after:  no function                  (mklipo.sh: 1 false positive → 0)

  func Hello(a int) string {        →  1:function:Hello     (Go)
  pub fn a(x: u8) -> u8 {           →  3:function:a         (Rust)
  public class C { public void m()  →  class C, function m  (Java)
  go() {                            →  function go           (shell)
```

## Why the comment mattered

The detector looks for an identifier before a `(`; a comment is full of prose containing parentheses, so any line whose comment ends in `)` looked like a definition. Cutting at ` #` / `//` (after the code, not inside a string by inspection) removes the whole class.

## Residual, measured and recorded

On this repository's shell scripts `outline` reports 137 functions where a `^name()` grep finds 120. The excess is shell-idiom noise inside test scripts (`ck "…" "$( … )"` lines and here-doc fragments), not yet reduced — which means the shell kind should be treated as *best effort* rather than authoritative, unlike the C count (52/52 and 24/24 against ast-grep).

## Tests

`tests/new-applets.sh` section **O6** pins Go, Rust (`fn` and `pub fn`), Java (class and method), shell and the comment case — 69 checks in that suite. Alongside: `timeline-query` 42, `test.sh` 198, `agent-ops` 1299, `streams` 37, `plugin-reports` 26. Patch `0022` regenerated; `patchcheck` → `checked=22 bad=0`.
