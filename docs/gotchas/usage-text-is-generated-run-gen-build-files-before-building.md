---
title: "`//usage:` edits need gen_build_files before the build, or help stays stale"
kind: "gotcha"
summary: "`//usage:` edits need `src/scripts/gen_build_files.sh . .` before the next build or the binary keeps printing the old help; `--caps` and the objects update without it, so nothing looks wrong."
tags: [help, usage, gen_build_files, caps, patch-0006, patch-0008]
created: "2026-11-23T21:13:57.107Z"
updated: "2026-11-23T21:13:57.107Z"
---
A `//usage:` edit does not reach the binary on the next `./build.sh` — busybox compiles help text from a generated `include/usage.h`, so `cd src && ./scripts/gen_build_files.sh . .` has to run first. Without it every other change compiles in and `--help` still prints the previous flags.

```text
  edit //usage: in src/coreutils/run.c
        ↓
  ./scripts/gen_build_files.sh . .     ← the step that is easy to forget
        ↓
  ./build.sh <target>                  → log --help shows --since/--summary/--marks …
```

## Symptom

`grep -c 'around-gap' src/coreutils/run.c` → 3, `build/<target>/coreutils/run.o` rebuilt, the binary relinked, `--caps` reflected a new feature — and `log --help` still listed only the old options, because `build/<target>/include/usage_compressed.h` had no `around-gap`. Nothing errors; the help is simply stale.

## What now documents itself

- `log --help`: `--since`, `--until`, `--around-gap`, `--limit`, `--sample`, `--summary`, `--marks`, `--diff-timeline` alongside the original range/match/stream flags.
- `run --help`: includes `-n/--stamp-ns`.
- `--caps --format json .features`: 19 entries — `gnu-long-opts, peek, replace, waitfor, run, log, doctor, json, brief, timeline, pty, brief-json, error-ids, stamp-ns, idle-timeout, log-query, mark, outline, patchapply`.

`tests/new-applets.sh` section H asserts these lines exist, so a future flag that is accepted but undocumented fails a test rather than living only in a commit message. Suite total 30 checks; alongside `timeline-query` 42, `test.sh` 198, `agent-ops` 1299, `streams` 37, `plugin-reports` 26. Patches `0006`/`0008` regenerated and reverse-checked; `patchcheck` → `checked=22 bad=0`.
