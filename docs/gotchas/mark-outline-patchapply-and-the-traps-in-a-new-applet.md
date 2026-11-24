---
title: "mark, outline, patchapply — and the traps in adding an applet"
kind: "gotcha"
summary: "`mark`/`outline`/`patchapply` ship; a new applet needs its own sha256-hex and JSON escaper, `<applet>_main_main`, hunk arrays allocated before parsing, and the correct getopt bit position."
tags: [mark, outline, patchapply, applets, getopt, patch-0022]
created: "2026-11-23T18:29:57.235Z"
updated: "2026-11-23T18:29:57.235Z"
---
The last three contract proposals exist as applets: `mark` (name a phase on the run's own clock), `outline` (definitions with line, byte and version), and `patchapply` (unified diff, every hunk verified before any write). `run` now exports `BUSYBOX_RUN_ID` and `BUSYBOX_RUN_DIR` so `mark` lands on the right run.

```text
  $ run -- sh -c "$B mark phase:build; build; $B mark phase:test"
  $ log R4 --marks
  phase:build   at 17695.209377  (+0.000000 from previous)
  phase:test    at 17695.326529  (+0.117152 from previous)

  $ outline t.c        5:class:39:Foo   7:heading:54:Title   + version=sha256:…
  $ patchapply -n p.patch   f.txt: ok hunks=1 +1 -1
  $ patchapply -c "g.txt=sha256:73cb3858a687" g.patch   # prefix from peek accepted
```

## What broke while building them, in order

1. **`sha256_hex` is not in libbb.** `peek` and `replace` keep static copies; a new applet has to write the `sha256_begin/hash/end` + hex loop itself (or include the file that has it).
2. **`json_write_str` is static in `peek.c`/`run.c`.** `json_read.h` exports parsing, not escaping. A new applet needs its own escaper — seven lines, but the linker error is what tells you.
3. **The entry point is `<applet>_main_main`,** not `<applet>_main`: `Undefined symbols: "_patchapply_main_main"` means the file defines the wrong symbol even though everything else compiles.
4. **Allocate a hunk array before parsing.** `parse_patch()` writes `cur->h[cur->nh++]`, so allocating `h` after the parse segfaults on the first hunk.
5. **`getopt32long` bits are the position of the letter in the optstring.** `--marks` (letter `K`, 16th) needed `1 << 15`; `1 << 17` silently disabled it and `log` fell through to the ordinary stream view — the same mistake as `--summary` earlier in the session.
6. **`@@ -1 +1 @@` has no counts.** A hunk parser that only accepts `-a,b +c,d` reports "not a unified diff" for the most common minimal patch.

## Registration, not forgetting it

A new applet needs: the file with `//config`/`//applet`/`//kbuild`/`//usage`, `CONFIG_X=y` in **both** `EXTRA_CONFIG` blocks of `build.sh`, and `cd src && ./scripts/gen_build_files.sh . .` — without that last step the applet is absent from `--list` and every call prints `mark: applet not found` while the build looks fine.

Suites: `tests/new-applets.sh` 21 checks, `timeline-query` 42, `test.sh` 198, `agent-ops` 1299, `streams` 37, `plugin-reports` 26. New patch `0022`; `patchcheck` → `checked=22 bad=0`.
