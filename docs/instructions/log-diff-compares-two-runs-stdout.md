---
title: "`log --diff R1:R2` compares two runs' stdout (patch 0008)"
kind: "instruction"
summary: "`busybox log --diff R1:R2` diffs two runs' stdout line by line (exit 1 when they differ, JSON changes[] capped at 20) and is peeled off argv before getopt so other flags still parse."
tags: [log, diff, patch-0008, section-14-1, agent-features]
created: "2026-11-22T15:23:39.743Z"
updated: "2026-11-22T15:23:39.743Z"
---
`busybox log --diff R1:R2` compares the stdout artifacts of two runs line by line — the before/after evidence loop that AGENT-FEATURES §14.1 calls the core debugging workflow. Lives in `src/coreutils/run.c`, shipped in `patches/0008-agent-ops-run.patch`.

```text
  log -D DIR --diff R1:R2
        ├─ peel --diff off argv before getopt32long   (so -l/-m/-D stay intact)
        ├─ read DIR/R1/stdout + DIR/R2/stdout         (missing → NOT_FOUND, exit 1)
        └─ compare line by line, show first 20        exit 1 when they differ
```

```
$ log -D /tmp/lr --diff R1:R2
line 2
  - two
  + TWO
lines=2 changed=1            # exit 1

$ log -D /tmp/lr --diff R1:R2 --format json
{"schema":1,"status":"ok","changes":[{"line":2,"a":"two","b":"TWO"}],"lines":2,"changed":1}

$ log -D /tmp/lr --diff R9:R2
/tmp/lr/R9/stdout: NOT_FOUND   # exit 1
```

## Why `--diff` is not a normal option

`log` parses `getopt32long(argv, "l:m:c:s:MB:D:F:", …)` and then takes `argv[optind]` as the run id. Adding a second positional (`log --diff R1 R2`) would collide with that, so `--diff R1:R2` is a single colon-joined argument **removed from `argv` by a pre-scan** before `getopt32long` runs. Anything that appends an option after `--diff` therefore still works.

## Contract behaviour

- Output compares only stdout; use two `log` calls for stderr.
- Exit **1** means "the runs differ" (like `diff` and `snapshot --diff`), 0 means identical — both inside the contract's 0/1/2/3 range.
- JSON is `{"schema":1,"status":"ok","changes":[{line,a,b}],"lines":N,"changed":M}`, capped at the first 20 differing lines; a missing artifact is `code:"NOT_FOUND"` with exit 1.

Suite after the change: 1299 passed on darwin-arm64, `busybox patchcheck` → checked=14 bad=0.
