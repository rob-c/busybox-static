---
title: "hush segfaulted on ETX: the byte is its own variable marker (fixed)"
kind: "gotcha"
summary: "hush segfaulted on a literal 0x03 because that byte is its internal variable marker; now rejected in i_getch with a clear message instead of a NULL deref."
tags: [hush, segfault, parser, fixed, special_var_symbol, fuzzing]
created: "2026-11-22T01:07:06.100Z"
updated: "2026-11-22T01:53:55.074Z"
---
`hush` used to die with SIGSEGV on a script containing byte **0x03 (ETX)** inside a command substitution. Fixed here: it now refuses the byte with a message instead of crashing.

```text
 before:  printf '\140\003\140' | busybox hush   ->  Segmentation fault: 11
 after:   printf '\140\003\140' | busybox hush   ->  hush: script contains byte 0x03,
                                                     which hush uses internally   (rc 1)
```

## Root cause: the byte is hush's own marker

`src/shell/hush.c` defines `SPECIAL_VAR_SYMBOL = 3` and encodes variable references inside its `o_string` buffers with that byte. A *literal* 0x03 read from the script is indistinguishable from a generated marker, so the expansion machinery walked a corrupted buffer and dereferenced NULL — first in `expand_one_var` (`*p = '\0'` with `p == NULL`), and after guarding that, in `expand_vars_to_list`.

Guarding each NULL is whack-a-mole: the buffer is already corrupt by then. The fix belongs where the byte enters:

```c
 out:   /* in i_getch(), the single chokepoint for all script input */
	if (ch == SPECIAL_VAR_SYMBOL)
		bb_error_msg_and_die("script contains byte 0x03, which hush uses internally");
```

`i_getch()` is the funnel for file, `-c` and stdin sources, so one check covers every path. The existing `NULL` guard in `expand_one_var` stays as defence in depth.

## Why only 0x03?

Sweeping 0x00–0x1f through `` `X` `` showed 0x01 and 0x02 are escaped by the single-quote and `$'...'` lexer paths (`ch == SPECIAL_VAR_SYMBOL` is converted to a quoted-variable reference there), and everything else is ordinary text. 0x03 reaching the *unquoted* lexer path was the one hole.

## Regression check

`adversarial.sh` tracked this as a `KNOWN` failure so a fix would be noticed: after the change it reports `pass: 1269 fail: 0 known: 0`, i.e. the case flipped from KNOWN to PASS. `test.sh` 168/168 and `stress.sh` 259/0 confirm ordinary hush scripts are unaffected (`for` loops, functions, `$( )`, backticks, `printf` all still work).

**This is a real fix worth upstreaming** — any script containing 0x03 could segfault hush, and hush is reachable as `sh` in some builds.
