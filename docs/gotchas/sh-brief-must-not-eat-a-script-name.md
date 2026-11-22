---
title: "`sh --brief` must not eat a script name as its value"
kind: "gotcha"
summary: "`sh --brief` consumed any following token as its stream value, so `sh --brief script.sh` failed with exit 2; only `stdout|stderr|both` may be consumed."
tags: [sh, ash, brief, getopt, patch-0004]
created: "2026-11-22T18:44:19.637Z"
updated: "2026-11-22T18:44:19.637Z"
---
`busybox sh --brief` takes an optional stream word and nothing else: `stdout` (default), `stderr`, or `both`. Any other following token is left in place, so `sh --brief script.sh one two` runs the script with its arguments instead of swallowing the script name as the value.

```text
  sh --brief -c '…'               stdout reduced          (default)
  sh --brief both -c '…'          both streams reduced
  sh --brief stdout script a b    script runs with a b    (fixed)
  sh --brief script a b           same — script not eaten (fixed)
```

## The bug

The option was stripped with `(argv[i+1] && argv[i+1][0] != '-') ? argv[++i] : "stdout"`, so any script name was consumed as the stream value and then rejected:

```
$ sh --brief s.sh one two
sh: --brief is stdout, stderr or both       exit 2
```

Consuming the next token only when it equals `stdout`, `stderr` or `both` fixes it, and keeps `sh --brief both -c …` working. Because the shell and `run` share the same vocabulary, the valid values are a closed set — worth checking explicitly rather than inferring from "does not start with a dash".

## How this was found

Auditing every `run`/`log`/`sh` flag against its neighbour after the `--brief`, `--brief-json`, `--quiet`, `--timeout` work landed: option bits are counted by position in `getopt32long`'s optstring, so a miscounted bit silently aliases another flag. The `run`/`log` table (timeout, kill-after, max-bytes, capture, cwd, dir, stdin, shell, pgid, prune, brief, brief-json, quiet; lines, match, context, meta, stream) all behaved correctly; only the shell's optional-argument rule was wrong.

Suites after the change: agent-ops 1299, test.sh 198, timeout-resilience 50, matrix 200 — all green.
