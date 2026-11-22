---
title: "Scripted #if-wrapping of applet bodies: four ways it breaks, and the rename+dispatch pattern"
kind: "gotcha"
summary: "Scripted #if-wrapping of busybox applet bodies fails four ways: duplicate anchors, brace-matching over strings, */ inside comments, missing forward declarations — rename + dispatch instead."
tags: [darwin, patching, ifdef, vmstat, mpstat, scripts]
created: "2026-11-21T19:24:22.279Z"
updated: "2026-11-21T19:24:22.279Z"
---
Adding a Darwin code path to a busybox applet is nearly always the same shape: rename the `/proc`-based function, add a Darwin one, and dispatch between them. Doing that with a scripted patch has four failure modes, and this session hit all four.

```text
 1  same anchor twice   -> two insertions, one #if, two #endifs
 2  brace-match a body  -> braces inside strings fool the counter
 3  */ inside a comment -> comment closes early, rest becomes code
 4  dispatcher too early-> "undeclared identifier" for the renamed fn
```

## 1. Never use the same `old` string twice in one patch script

`once(old, new)` helpers that assert-and-replace are the usual way to script these edits. If two of them target the same comment (I anchored twice on `/*\n * Read IRQs from /proc/stat\n */` in `procps/mpstat.c`), the second insert lands inside the first one's output and the `#if`/`#endif` pairing breaks: `#endif without #if` plus `unterminated conditional directive`. Give every insertion a unique, adjacent anchor, or apply them in one pass with explicit string surgery.

## 2. Do not brace-match a function body to wrap it in `#if`

`vmstat.c`'s `load_row()` contains `{` and `}` inside string literals (`coldescs[]`). A naive depth counter ends the function at the wrong brace, and the real body lands outside any function (`type specifier missing, defaults to 'int'`). Rename the original instead (`load_row` -> `load_row_proc`) and add a two-line dispatcher — no matching required.

## 3. A `*/` inside a comment closes the comment

`/* No /proc/*/{cwd,exe,root,fd}: ... */` looks harmless; the `*/` in `proc/*/` terminates the comment and `{cwd,exe,root,fd}: ...` becomes code (`expected identifier or '('` reported at the comment line). Write `/proc/PID/{...}`.

## 4. Forward-declare the renamed function

A dispatcher placed above the renamed body needs `static void foo_proc(...);` first, or the build says `call to undeclared function 'foo_proc'` and then `static declaration follows non-static declaration` when the body appears later.

## The verified pattern

1. rename: `static void foo(...)` -> `static void foo_proc(...)` (body untouched);
2. insert the Darwin implementation above it, wrapped in `#if defined(__APPLE__) ... #else` / `#endif` with the `#endif` immediately after the *renamed* body;
3. put the dispatcher after both, calling `foo_darwin_impl()` / `foo_proc()`.

`procps/vmstat.c` in patch 0004 is a working example; `procps/mpstat.c` was reverted because of failure 1.
