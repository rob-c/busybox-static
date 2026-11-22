---
title: "Agent-ops plan lives at the repo root and reserves patch 0006"
kind: "decision"
summary: "The agent-ops proposal is AGENT-FEATURES.md at the repo root (not docs/), reserving patch 0006; it keeps P0 caps/peek/waitfor, P1 replace+json_read, P2 run/log and drops Pi wiring entirely."
tags: [proposal, agent-features, patch-0006, applets, scope]
created: "2026-11-22T02:23:31.064Z"
updated: "2026-11-22T02:23:31.064Z"
---
The agent-ops plan lives at the repository root as `AGENT-FEATURES.md`, next to `README.md` and `RELEASING.md`, not in `docs/`: `docs/` holds things this port already learned, while that file is a proposal for work not yet done. It reserves patch number `0006` (0005 is the darwin df/mount patch) and keeps the whole feature set in one droppable diff so 0002–0005 stay untouched.

```text
  brief ──► filter ──► AGENT-FEATURES.md ──► 0006-agent-ops.patch
              │                │
              │                ├─ P0: busybox --caps, peek, waitfor
              │                ├─ P1: replace, libbb/json_read, batch
              │                └─ P2: run/log, doctor
              └─ dropped: Pi extension (separate plugin project), MCP,
                 job daemons, AST indexes, `wait` as a name, help --json
                 for existing applets
```

## Why the shape is what it is

- **One `.c` file per applet** carrying `//config:` / `//applet:` / `//kbuild:` / `//usage:` (`util-linux/column.c` is the precedent) means no central applet table and none of the `find -printf` params-ordering or `getopt32` bit-position traps.
- **New applets call `getopt32long()`** so they need no row in `libbb/gnu_longopts.c`; that table exists only for legacy short-only applets.
- **`getopt32()` calls `bb_show_usage()` on a bad option** (`libbb/getopt32.c:600`), so a `--format json` applet must pre-scan argv or the error escapes as text.
- **`timeout` cannot be delegated to**: it exits 128+signal (143/137), so the `run` applet owns its own deadline (docs/gotchas/timeout-exits-128-plus-signal-not-124.md).
- **`replace` copies `sed -i`'s temp+rename idiom** (`editors/sed.c:1640-1664`: `xmkstemp` in the same directory, `fchmod`/`fchown`, `ferror` check, `xrename`) instead of inventing a write path, and refuses symlinks where `sed -i` silently replaces the link.
- **New CONFIG symbols must be set in `build.sh`'s `EXTRA_CONFIG`**, not in `build/<target>/.config`, because `build-all.sh` wipes build dirs.

## Status

Proposal only — nothing implemented. `README.md`'s Layout block now lists the file, and its stale "94 checks" / "the two patches" lines were corrected to 168 checks and five patches.
