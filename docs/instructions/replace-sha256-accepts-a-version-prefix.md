---
title: "`replace --sha256` accepts a version prefix (patch 0007)"
kind: "instruction"
summary: "`replace --sha256` compares a shortened hash as a prefix, so the 12 hex digits `peek` prints can be handed straight back; full hashes still compare exactly and a wrong prefix fails with STALE_INPUT."
tags: [replace, sha256, patch-0007, busybox-contract, stale-input]
created: "2026-11-22T17:16:26.884Z"
updated: "2026-11-22T17:16:26.884Z"
---
`busybox replace --sha256` accepts a shortened hash, so the 12 hex digits `peek` prints in text mode can be handed straight back as the precondition. Comparison is `strncasecmp` over the supplied length when it is under 64 characters; a full hash is still compared exactly. Ships in `patches/0007-agent-ops-edit.patch`.

```text
  peek f.ts --lines 1:1 --format json   → version "sha256:444b84fce062ab4d…"
  peek f.ts (text)                      → version=sha256:444b84fce062   (12 digits)

  replace f.ts --old A --new B --sha256 444b84fce062
      ├─ supplied length < 64  → prefix compare   (matches: proceed)
      └─ supplied length = 64  → exact compare
  wrong prefix             → STALE_INPUT, nothing written
```

## Why it matters

BUSYBOX-CONTRACT.md §3 states the plugin resolves the short prefix itself before calling `--sha256`, and that a build accepting prefixes would be "redundant but harmless". Without this, an agent that copies `version=sha256:444b84fce062` out of `peek`'s **text** output gets `STALE_INPUT` on a file it just read — a confusing failure that looks like a race.

## Guard strength

Unchanged: the comparison still happens inside the lock against the freshly read file, and any mismatch (including a prefix that is not a prefix of the truth) fails with `code=STALE_INPUT` and writes nothing. A supplied hash longer than 64 characters falls into the exact-compare branch and fails.

Suite after the change: 1299 passed on darwin-arm64; `busybox patchcheck` -> checked=14 bad=0.
