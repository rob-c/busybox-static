---
title: "`--brief-json` emits brief's schema-1 payload in run and sh"
kind: "instruction"
summary: "`--brief-json` on run/sh emits brief's schema-1 JSON; `run --format json` adds nested `stdout_brief`/`stderr_brief` objects beside the text views."
tags: [brief, json, run, sh, patch-0004, patch-0008]
created: "2026-11-22T17:59:50.844Z"
updated: "2026-11-22T17:59:50.844Z"
---
`--brief-json` makes the reduction in `run` and `sh` emit brief's own schema-1 JSON instead of the text view. `run --format json` additionally embeds that payload as `stdout_brief` / `stderr_brief` objects, so counts and items are readable without re-parsing a string.

```text
  run --quiet --brief stdout --brief-json -- sh -c 'for i in 1 2 3; do echo same; done'
      {"schema":1,"summary":"4 lines in, 2 records, …","lines_in":4,"records":2,
       "lines_merged":2,"items":[{"n":3,"lines":3,"line":"same"}, …]}

  run --brief both --brief-json --format json -- cmd
      {"schema":1,…,"stdout_view":"{\"schema\":1,…}","stderr_view":"…",
       "stdout_brief":{"schema":1,…,"records":1},"stderr_brief":{"schema":1,…}}

  sh --brief stdout --brief-json -c '…'          one payload per selected stream
  sh --timeout 5 --brief stdout --brief-json -c '…'    forwarded through run
```

## Wiring

`brief_reduce()` gains a `json` argument and passes `-F json` to the forked reducer; the child is the only place brief parses options, so busybox's global getopt state stays private. In `run --format json` the payload is emitted as a nested object via `trim_json()`, which strips the trailing newline and rejects anything that is not an object — a reducer that failed leaves the key out rather than emitting invalid JSON.

## Compatibility

Without `--brief-json` nothing changes: the text view, `stdout_view`, and every existing key keep their shapes. Adding `stdout_brief`/`stderr_brief` is an additive field, which BUSYBOX-CONTRACT.md §7 lists as safe.

Suite: agent-ops 1299 passed, core 198 passed; `busybox patchcheck` -> checked=14 bad=0.
