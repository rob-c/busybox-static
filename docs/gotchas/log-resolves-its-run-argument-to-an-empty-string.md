---
title: "`log -D DIR RUN` resolves RUN to an empty string (path shows `DIR//stdout`)"
kind: "gotcha"
summary: "`busybox log -D DIR RUN` looks up `DIR//stdout` because the positional RUN arrives empty; the double slash in the NOT_FOUND path is the giveaway, and it breaks every log.* check."
tags: [log, argv, getopt32, regression, tests]
created: "2026-11-22T14:02:35.224Z"
updated: "2026-11-22T14:02:35.224Z"
---
`log -D DIR RUN` resolves `RUN` to an empty string, so it looks up `DIR//stdout` and reports `NOT_FOUND` even though the run exists. The double slash is the tell: `dir = xasprintf("%s/%s", root, run)` with `run == ""`. This breaks every `log.*` and `run.meta.*` check in `tests/agent-ops.sh`.

```text
$ busybox run -D $PWD/r -- sh -c 'printf "out1\n"; printf "err1\n" >&2'
run=R1 exit_code=0 …                       <- the run is fine, artifact exists
$ ls r
R1
$ busybox log -D $PWD/r R1 --lines 1:1
/tmp/ct/r//stdout: NOT_FOUND               <- "r//": RUN came through empty
```

## Where to look

`log_main()` in `coreutils/run.c` parses `getopt32long(argv, "l:m:c:s:MB:D:F:", …)` and then does `argv += optind; … run = argv[0];`. Either `optind` lands past the positional argument, or the `M` flag (a `No_argument` inside an otherwise argument-taking optstring) confuses the permutation. Two candidate fixes: prefix the optstring with `+` so parsing stops at the first non-option, or capture the positional before advancing `argv`.

## How to prove the fix

```sh
busybox run -D /tmp/r -- true
busybox log -D /tmp/r R1 --lines 1:1        # must print "stdout lines=1-1", not NOT_FOUND
./tests/agent-ops.sh dist/darwin-arm64/bin/busybox   # log.* and run.meta.* must pass
```

A regression check worth adding: assert that `log -D DIR R1` resolves to `DIR/R1/stdout`, so an empty positional can never pass silently again.
