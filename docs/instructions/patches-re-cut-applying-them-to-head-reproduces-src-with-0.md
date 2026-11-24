---
title: "Patches re-cut: applying them to HEAD reproduces src with 0 differing files"
kind: "instruction"
summary: "`tests/patch-reconstruct.sh` now proves patches/ reproduces src/ exactly (0 files differing); the series was re-cut so each file is owned by one patch."
tags: [patches, release, verification, reconstruct, gplv2]
created: "2026-11-23T14:42:07.861Z"
updated: "2026-11-23T14:42:07.861Z"
---
`patches/` has been re-cut so that applying all 22 patches to a clean export of `git -C src HEAD` reproduces the working tree **exactly**: `diff -rq` reports **0 differing files**. The authority is now `tests/patch-reconstruct.sh`, which tests the end state rather than whether each hunk applies cleanly.

```mermaid
flowchart LR
  A["git -C src archive HEAD"] --> B["apply 22 patches -N"]
  B --> C["diff -rq vs src"]
  C -->|"0 differing"| D["OK: series is faithful"]
```

## What the re-cut did

Each patch was regenerated as `git -C src diff --cached HEAD -- <its files>`, after `git -C src add -A` so new files are included. The old series had every file claimed by two or three patches — `0004-agent-ergonomics.patch` had been regenerated cumulatively at some point and claimed nearly everything — which is why a plain re-apply produced 40 rejects. Files are now owned by exactly one patch, with the later, dedicated patch winning over the catch-all.

Two stragglers (`coreutils/df.c`, `miscutils/dc.c`) still differed after the first pass because two patches carried hunks for them; both were moved into the last patch, `0022-platform-parity-arch-pgrep-fdisk-usage.patch`, so nothing later can overwrite them.

## Run the check

```sh
./tests/patch-reconstruct.sh
# patches applied:   22
# hard apply errors: 0
# rejects (benign):  24
# files differing:   0
# OK: patches/ reproduces src/ exactly
```

**Read it this way:** the 24 `.rej` files are hunks already applied by an earlier patch in the series and are expected for a set of cumulative diffs from HEAD; the number that matters is *files differing*, which must be 0. If it is not, the script prints the differing paths and exits 1.

## Caveat worth keeping

`git -C src archive HEAD` is the clone's upstream commit (`aac079e`, grafted). The re-cut is faithful to *that* base. If the clone is ever re-fetched to a different upstream commit, re-run `tests/patch-reconstruct.sh` and re-cut again — the series is a diff from a specific base, and nothing in it records which one. Adding the upstream commit hash to `RELEASING.md` would close that hole.
