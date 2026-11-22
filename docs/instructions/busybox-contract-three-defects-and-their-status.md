---
title: "BUSYBOX-CONTRACT.md: two of three defects fixed, spawn-failure still open"
kind: "instruction"
summary: "BUSYBOX-CONTRACT.md names three defects: truncated run JSON and the message-less 0-match replace are fixed in src/, the spawn-failure/SPAWN_FAILED one is still open; patches 0007/0008 are stale."
tags: [busybox-contract, pi-managed-tools, defects, run, replace, json]
created: "2026-11-22T13:57:16.603Z"
updated: "2026-11-22T13:57:16.603Z"
---
`BUSYBOX-CONTRACT.md` (identical copy in `busybox-static/` and `pi-managed-tools/`, 257 lines) is the consumer-side spec the pi plugin codes against, and it names three defects plus a compatibility checklist. Two are now fixed in `src/`; the third is diagnosed and needs its own edit.

```text
  BUSYBOX-CONTRACT.md §4/§6
    defect 1  run --format json emits two adjacent strings   FIXED  bounded_string()
    defect 2  spawn failure looks like child exit 127        TODO   SPAWN_FAILED, exit 1
    defect 3  0-match replace = INVALID_ARGUMENT, no msg     FIXED  NULL match set
    §6 related --request must stop on INVALID_ARGUMENT       FIXED  `if (o.code) break`
```

## The three defects

- **Defect 1** — `dump_bounded()` printed the head and the tail with two separate `json_write_str()` calls, producing `…"lin""e 34…` at the seam, which is invalid JSON. `bounded_string()` in `coreutils/run.c` now builds one buffer (head + `... [N bytes] ...` + tail) and escapes it once. Verify with the contract's own reproducer: `busybox run --max-bytes 120 --format json -- sh -c '…40 lines…' | python3 -c 'import json;json.load(sys.stdin)'`.
- **Defect 3** — `collect_matches()` returned `NULL` for "zero matches", indistinguishable from a regex/parse error, so `do_edit()` jumped to `fail` before the count check set a message. Now `NULL` without an error code falls through to the count check: `{"code":"NOT_FOUND","message":"expected 1 occurrence(s), found none"}`.
- **Defect 2 (open)** — a missing binary must be a wrapper failure: exit 1 plus `"code":"SPAWN_FAILED"`, keeping `exit_code` for children that actually ran. A PATH pre-check in `run_main` is the cheapest fix; the first two attempts failed because the `if (!argv[0]) bb_show_usage();` line exists in *both* `run_main` and `log_main`, so a global string replace put the block in `log_main`, where `use_shell` is not declared.

## The checklist worth reading before any change

Tell the plugin first if these move: any JSON field name, `next` losing its object shape, `results[]` around single-file `replace`, `--lines`/`--around` ceasing to be mutually exclusive, `version` becoming a range hash, `run`'s wrapper failures losing their distinctness, `--list`/`--caps --format json`/`log --meta` changing shape, exit codes leaving 0/1/2/3, or truncation ceasing to be exit 0. Adding applets and adding JSON fields is safe.

## State of the tree

`./build.sh darwin-arm64` → done after both fixes; both reproducers pass. `patches/0007` and `0008` are now **stale** relative to `src/` and must be regenerated (see docs/instructions/regenerating-a-tier-patch-means-its-whole-file-set.md), then `./tests/agent-ops.sh` re-run on Darwin and in an AlmaLinux container.
