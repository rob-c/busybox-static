---
title: "`replace --backup SUF` writes the original before editing (patch 0007)"
kind: "instruction"
summary: "`busybox replace --backup SUF` copies the original to PATHSUF inside the lock before renaming; build the path from `target`, not `resolved` (NULL for plain files → `(null).bak`)."
tags: [replace, backup, patch-0007, section-14-1, agent-features]
created: "2026-11-22T15:35:17.029Z"
updated: "2026-11-22T15:35:17.029Z"
---
`busybox replace --backup SUF` writes the pre-edit contents to `PATHSUF` before the atomic rename, giving recoverability without a VCS — AGENT-FEATURES §14.1. Lives in `src/editors/replace.c`, shipped in `patches/0007-agent-ops-edit.patch`.

```text
  replace f.txt --old world --new there --backup .bak
        ├─ read original under the lock
        ├─ write original bytes ──► f.txt.bak        (mode copied from the file)
        ├─ write edited tmp, rename over f.txt
        └─ on backup failure: INVALID_ARGUMENT, nothing replaced
```

```
$ replace f.txt --old world --new there --backup .bak
f.txt      → hello there
f.txt.bak  → hello world

$ ln -s g.txt link
$ replace link --follow --old a --new A --backup .orig
g.txt      → A          (the symlink target is edited)
g.txt.orig → a          (backup lands next to the target, not the link)
```

## The bug worth remembering

Using `resolved` for the backup path produced a file literally named `(null).bak`: `resolved` is only assigned in the `--follow` symlink branch, so for an ordinary file it is still `NULL`. Build the backup path from **`target`**, which equals `resolved` when following and the original path otherwise.

## Behaviour

- The backup is written from the in-memory original inside the same lock, so it is exactly the bytes that were searched — no re-read race.
- Failure to create or write the backup is `INVALID_ARGUMENT` and the edit is abandoned; nothing is renamed.
- Mode bits are copied from the source file, so a `0600` secret does not become world-readable through its backup.
- The option is `-K SUF` / `--backup SUF`; a suffix, not a filename (`.bak`, `.orig`, `~`).

Suite after the change: 1299 passed on darwin-arm64; `busybox patchcheck` → checked=14 bad=0.
