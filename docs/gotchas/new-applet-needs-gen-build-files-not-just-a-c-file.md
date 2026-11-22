---
title: "New applet needs `gen_build_files.sh`, not just a .c file"
kind: "gotcha"
summary: "A new applet is invisible (`applet not found`) until `src/scripts/gen_build_files.sh . .` regenerates the gitignored `include/applets.h`; and never `make oldconfig` by hand — it enables every default and breaks unrelated builds."
tags: [applets, gen_build_files, kconfig, oldconfig, check, patch-0014]
created: "2026-11-22T15:07:31.963Z"
updated: "2026-11-22T15:07:31.963Z"
---
`busybox check` runs a table of shell test cases and reports pass/fail per case plus a summary. It closes §14.2 of AGENT-FEATURES.md and replaces the hand-rolled pass/fail counting in `tests/agent-ops.sh` whenever a table is enough. Ships as `patches/0014-agent-ops-check.patch`; named `check` because `test`, `[` and `[[` are already applets.

```text
  # name | command | want_exit | want_substring
  true-runs   | true            | 0 |
  echo-hi     | echo hi         | 0 | hi
  bad-exit    | sh -c 'exit 3'  | 0 |

  → ok   true-runs / ok   echo-hi / FAIL bad-exit: exit 3, want 0
    total=4 passed=3 failed=1        exit 1
  --format json → {"schema":1,"status":"error","total":4,"passed":3,"failed":1,"cases":[…]}
```

## The registration trap that cost this turn

Adding a `.c` file with a `//applet:` line is **not** enough.

- **`src/include/applets.h` is a checked-in *generated* file and is gitignored.** If it is stale, the applet is silently absent from `--list` and every invocation prints `check: applet not found` — while `.config`, `autoconf.h`, `miscutils/Kbuild` and `miscutils/check.o` all look perfectly correct, and `nm` on the stripped binary proves nothing.
- Fix: run `cd src && ./scripts/gen_build_files.sh . .` (two args: SRCTREE OBJTREE) after adding or renaming an applet, then rebuild. Because the file is gitignored it cannot ship in a patch, so the patch carries only the `.c`.
- The generated header also decides the **symbol name**: with the entry regenerated it wants `check_main_main` (applet name + `_main`), so keep the `<name>_main_main` convention used by `json`, `bench`, `snapshot` and `patchcheck`.

## The other one: never hand-edit `.config` with `oldconfig`

Running `make oldconfig` interactively in `build/<target>` to "just accept" a new symbol answered **defaults for every other symbol**, which enabled dozens of applets and broke the build in an unrelated file (`miscutils/brief.c: undeclared function item_new_owning`). New `CONFIG_*` belong in `EXTRA_CONFIG` in `build.sh`; to recover, delete `build/<target>/.config` and let `build.sh` regenerate it from `defconfig`.

## Case format

`name | command | want_exit | want_substring`; `#` starts a comment; fields are trimmed. The command runs via `/bin/sh -c` with stdout captured through a pipe (first 8 KiB kept), so a substring check can look at output without a temp file.
