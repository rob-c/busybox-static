---
title: "`run --pgid` exposes the child's process group (patch 0008)"
kind: "instruction"
summary: "`busybox run --pgid` prints the pgid setpgid already created (text summary, JSON field, and the meta file); its option bit is 1<<9 — 1<<8 is --format."
tags: [run, pgid, patch-0008, section-14-1, agent-features]
created: "2026-11-22T15:44:42.192Z"
updated: "2026-11-22T15:44:42.192Z"
---
`busybox run --pgid` exposes the process group that `run` already created with `setpgid`, so an outside caller can `killpg` a run's whole descendant tree without guessing the number. AGENT-FEATURES §14.1; ships in `patches/0008-agent-ops-run.patch`.

```text
  run --pgid -- cmd      ──►  summary line:  pgid=9019
  run --format json      ──►  {"schema":1,"run":"R5","pgid":9022,"exit_code":0,…}
  log R5 --meta          ──►  meta file gains  pgid=9022
```

## Details

- `child_pgid` is recorded on the parent side right after `setpgid(pid, pid)`, so it equals the child's pid and is valid before the child has exec'd.
- The JSON field is **always** present now (additive — the contract allows added fields); the text summary line appears only with `--pgid`, so existing text consumers are unaffected.
- The meta file carries `pgid=` unconditionally, which is what makes `log --meta` usable for cleanup: read the group, `killpg` it.
- `--prune` (the companion cleanup flag in the same row) is **not** implemented yet.

## Option-bit trap

`run`'s optstring is `"T:k:B:C:D:d:sF:i:P"`. `P` is the **tenth** entry, so its bit is `1 << 9`, not `1 << 8`; testing `1 << 8` silently reads `F` (`--format`) and the flag never fires. Count the option letters before trusting a shift.

Suite after the change: 1299 passed on darwin-arm64; `busybox patchcheck` → checked=14 bad=0.
