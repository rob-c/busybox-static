---
title: "Releasing after a merge batch: verify, fold Unreleased, then tag"
kind: "instruction"
summary: "A merge-and-release lands uncommitted work from another session: verify with every suite first (including new ones like pty), fold Unreleased sections into the version, then build-all, pack, tag v$(cat VERSION), release."
tags: [release, packaging, pty, merge, gh]
created: "2026-11-23T00:18:15.002Z"
updated: "2026-11-23T00:18:15.002Z"
---
Release 0.5.0 shipped `run --pty`, the wrapper-kill watchdog and two `run` bug fixes. The release procedure is unchanged from 0.4.0; what is worth writing down is that a merge-and-release lands *after* verifying the tree, because the batch arrives uncommitted and can contain its own test suites.

```text
  git status          uncommitted work from another session
        ↓
  ./build.sh darwin-arm64    + every suite (pty 100, agent-ops 1299, …)
        ↓
  git commit "merge: …"      then  CHANGELOG "## 0.x.0"  +  VERSION
        ↓
  ./build-all.sh (6 targets)  →  ./pack-release.sh   (51 assets)
        ↓
  git tag -a v0.x.0 && git push origin main v0.x.0
        ↓
  gh release create v0.x.0 --notes-file NOTES-0.x.0.md release/<stamp>/*
        ↓
  download one asset back: shasum -c  +  run a feature it claims
```

## 0.5.0 specifics

- Two `Unreleased` sections existed; both fold into `## 0.5.0` (one as a `###` sub-section), because the watchdog work landed after the 0.4.0 tag.
- The bundle is generated per upstream stamp (`release/v1.39.0-aac079e/`), so re-running `pack-release.sh` overwrites the previous bundle: generate the notes file (`NOTES-0.5.0.md`) **after** packing, and never assume the directory still holds the old release.
- Verification that matters: `docker run … almalinux:9 bash /w/tests/pty.sh /w/dist/linux-arm64/bin/busybox` → 100/100, since the pty path is the one piece that depends on the platform's `/dev/pts` behaviour.
- Post-upload check for this release: download `busybox-static-1.39.0-aac079e-darwin-arm64`, `shasum -a 256 -c`, then `run --pty --quiet -- sh -c 'test -t 1 && echo tty-yes'` → `tty-yes`.

Suites at tag time: test.sh 198 · agent-ops 1299 (1318 Linux) · pty 100 (both platforms) · streams 37 · wrapper-signals 21 · reaper 50 · timeout-resilience 50 · matrix 200 · `patchcheck` → checked=15 bad=0.
