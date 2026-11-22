---
title: "Regenerating a tier patch means its whole file set, verified with `git apply --check -R`"
kind: "instruction"
summary: "`git diff -- <paths>` is against HEAD, so a one-line change to a file owned by 0006 requires regenerating all of 0006; verify with `git apply --check -R`, and `git add -N` new files first."
tags: [patches, git, workflow, regeneration, reverse-check]
created: "2026-11-22T13:48:32.817Z"
updated: "2026-11-22T13:48:32.817Z"
---
Regenerating a tier patch must include every file that patch owns, because `git diff -- <paths>` produces a diff against HEAD, not against the previous patch. Adding a one-line `--caps` field to `libbb/appletlib.c` therefore means regenerating the *whole* of `0006-agent-ops-core.patch`, not appending a hunk.

```text
  HEAD ──────────────────────────────────────► working tree
        \                                        /
         \  git diff -- <file set> gives the    /
          \ WHOLE delta for those files        /
           ▼                                   ▼
   patches/0006 (appletlib.c, peek.c, waitfor.c, json_read.*)
   patches/0007 (replace.c)       patches/0008 (run.c, doctor.c)
   patches/0009 (why.c)           patches/0010 ... next tranche
```

```sh
cd src
git add -N miscutils/why.c          # new files must be intent-to-added first
git diff -- libbb/appletlib.c coreutils/peek.c miscutils/waitfor.c \
            libbb/json_read.c include/json_read.h miscutils/why.c \
	> ../patches/0006-agent-ops-core.patch
git diff -- editors/replace.c        > ../patches/0007-agent-ops-edit.patch
git diff -- coreutils/run.c miscutils/doctor.c > ../patches/0008-agent-ops-run.patch
git diff -- miscutils/why.c          > ../patches/0009-agent-ops-why.patch
for p in 0006-agent-ops-core 0007-agent-ops-edit 0008-agent-ops-run 0009-agent-ops-why; do
	git apply --check -R ../patches/$p.patch && echo "$p ok"
done
```

## Rules

- **One patch per tier, disjoint file sets.** `why.c` alone is `0009`; the moment a change touches `appletlib.c` it belongs to `0006` and `0006` is regenerated wholesale.
- **Reverse-check is the proof.** `git apply --check -R` shows the diff is exactly HEAD→worktree; a forward check on a tree that already holds the change proves nothing.
- **`git add -N` for new files**, else `git diff` omits them and the patch builds a binary that a clean clone cannot compile.
- **`build.sh`, `test.sh`, `README.md`, `AGENT-FEATURES.md` are repo files**, not patch content.

Observed: `busybox --caps --format json` gained `"build":{"size":873104}`; all four patches pass the reverse check and `./build.sh darwin-arm64` reports done.
