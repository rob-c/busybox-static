---
title: "Verifying the BUSYBOX-CONTRACT.md shapes against a built binary"
kind: "instruction"
summary: "One-liners that re-verify every BUSYBOX-CONTRACT.md requirement (peek next object, whole-file version, replace version guard, run exit passthrough, SPAWN_FAILED, NOT_FOUND message) against a built binary."
tags: [busybox-contract, verification, run, replace, peek, regression]
created: "2026-11-22T14:08:32.583Z"
updated: "2026-11-22T14:08:32.583Z"
---
The three defects `BUSYBOX-CONTRACT.md` names are fixed and every shape in its §7 compatibility list still holds. These one-liners prove it against a built binary, so a fresh clone can re-verify the contract without the pi plugin.

```text
  contract section   command                                   expect
  §2 peek            peek --max-bytes 6 --format json f.txt    "next":{"from_byte":N}, version sha256:<64>
  §3 replace         replace --sha256 <peek version>           "status":"ok", no results[]
  §4 run             run -- sh -c 'echo hi; exit 4'            log --meta: exit_code=4
  §4 run (truncate)  run --max-bytes 20 --format json          parses with python3 -m json.tool
  §4 spawn           run --format json -- /nonexistent/prog    {"code":"SPAWN_FAILED"}, exit 1
  §6 replace         replace --old zzzz --new x                {"code":"NOT_FOUND"} + a message
```

## What each defect was

- **Truncated `run` JSON**: `dump_bounded()` escaped head and tail separately, producing `…"lin""e 34…`. `bounded_string()` in `coreutils/run.c` builds one buffer (head + `... [N bytes] ...` + tail) and escapes it once.
- **Spawn failure**: a missing binary surfaced as exit 127, indistinguishable from a child that chose 127. A PATH/`stat` pre-check before `fork` returns exit 1 with `"code":"SPAWN_FAILED"`.
- **Zero-match `replace`**: `collect_matches()` returned `NULL` for "no matches", indistinguishable from a regex error, so the error path fired before the message was set. `NULL` without a code now falls through to the count check.

## Regression to remember

`log` broke because the `run.c` rewrite dropped `run = argv[0];` — the symptom was a lookup of `$root//stdout`, and the double slash is the giveaway (empty run id). Check that assignment before suspecting `getopt32`.
