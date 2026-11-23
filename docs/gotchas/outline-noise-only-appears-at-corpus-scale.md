---
title: "Outline noise only appears at corpus scale: calls, directives, members"
kind: "gotcha"
summary: "Outline reported calls (`strcmp`), directives (`endif`) and members as definitions; three syntactic tests remove 126 false entries across six files, and the suite now measures ash.c."
tags: [outline, heuristics, patch-0022, testing]
created: "2026-11-23T21:45:46.862Z"
updated: "2026-11-23T21:45:46.862Z"
---
Run across six of this repository's own C files, `outline` produced 68 entries named `strcmp`, 39 named `endif` and 19 named `readtoken` — every one a line that merely *contains* a call or a preprocessor directive. The fixes are three tests in `kind_of()`.

```text
  src/shell/ash.c, six files    before            after
    function strcmp               68                0
    heading  endif                39                0
    function readtoken            19                0
  docs/README.md                (unchanged)   1:heading:0:Project notes
```

## The three rules

1. **A call is not a definition.** The identifier before `(` must not sit behind an operator (`(`, `,`, `=`, `!`, `&`, `|`, `+`, `-`, `/`, `<`, `>`, `?`, `%`), and the word before it must not be `if`, `while`, `for`, `switch`, `return` or `do`. That single check removed both `if (strcmp(…) == 0) {` and `readtoken() != NULL) {`.
2. **`#` is a heading only when followed by a space** *and* the first word is not a C directive (`include`, `define`, `undef`, `if`, `ifdef`, `ifndef`, `elif`, `else`, `endif`, `pragma`, `error`, `warning`, `line`, `import`). `# include <x.h>` and `# Title` are otherwise indistinguishable.
3. **A `struct`/`union` member is indented.** Only column 0 defines a type, which is what separates `struct item {` from `\tstruct sample smp[N];`.

## Measuring it, not guessing

The noise only appears at corpus scale: one file looks plausible, six files make the pattern obvious — 126 of one wrong entry type across a single header-heavy source. `tests/new-applets.sh` section **O4** now runs `outline` over `src/shell/ash.c` and fails if any `:heading:` appears, so the next regression is a test failure rather than a slow drift.

Suites: `new-applets` 57 · `timeline-query` 42 · `test.sh` 198 · `agent-ops` 1299 · `streams` 37 · `plugin-reports` 26. Patch `0022` regenerated; `patchcheck` → `checked=22 bad=0`.
