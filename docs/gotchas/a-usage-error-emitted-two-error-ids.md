---
title: "A usage error emitted two error ids; the text timeline kept only the head"
kind: "gotcha"
summary: "`--error-ids` printed both `E FAILED` and `E USAGE` for one usage error; getopt32 now marks it USAGE and bb_show_usage skips a duplicate id. Text timelines gained a tail."
tags: [error-ids, getopt32, timeline, patch-0003, patch-0006, patch-0008]
created: "2026-11-23T13:39:07.562Z"
updated: "2026-11-23T13:39:07.562Z"
---
A usage error under `--error-ids` emitted **two** ids (one `E FAILED` from getopt's option message, one `E USAGE` from `bb_show_usage`); it now emits exactly one, `E USAGE`. The text timeline also prints head **and** tail now, so a failing suite shows its failure without a second retrieval.

```text
  busybox --error-ids ls --nrs-bad-option
    before  stdout: E FAILED          stderr: ls: FAILED: unrecognized option: …
                    E USAGE
    after   stdout: E USAGE           stderr: ls: USAGE: unrecognized option: …

  run -t -B 600 -- sh -c '… 40 lines …'
    before  first M lines only
    after   lines 0-11
            ... [timeline truncated: 16 of 40 lines shown (24 omitted); `log R1 --stream timeline' has them] ...
            lines 36-39
```

## The double id

`getopt32.c` printed the option error before `bb_show_usage()` ran, and each of the two paths emitted its own id. The fix has two halves: `getopt32` sets `bb_error_code = "USAGE"` before that message (the usage text follows, so the id is USAGE, not FAILED), and `bb_show_usage()` skips its id when `bb_error_ids_sent` says one already went to stdout. One diagnostic, one id — the invariant `tests/streams.sh` checks.

## Text timeline head+tail

`tl_print_text()` printed a head-only view; the failing assertion is at the end, so the plugin had to spend a retrieval on `log RUN --lines N-40:N`. It now spends 3/4 of `--max-bytes` on the head and 1/4 on the tail with one marker line between, and reports `shown=` as head+tail so `truncated=true` still means "not all lines are here". The marker keeps the phrase `timeline truncated: N of M lines shown`, which existing greps (and the plugin digest) look for.

## Patch bookkeeping

Six patches describe this tree (0003 gnu-long-options, 0004 agent-ergonomics, 0006 agent-ops-core, 0008 agent-ops-run, 0014 brief, plus the 0016-0021 diagnostics set). Regenerate a patch from **its own** `+++ b/` file list, not a remembered one: `awk '/^+++ b\//{print $2}' patches/N.patch` — a wrong list silently drops files from the patch while the tree still builds.
