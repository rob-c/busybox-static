---
title: "Cutting a release: tag `v$(cat VERSION)`, not the busybox stamp"
kind: "instruction"
summary: "Release = bump VERSION + CHANGELOG, `./build-all.sh`, `./pack-release.sh`, tag `v$(cat VERSION)` (not pack-release's busybox tag), `gh release create` with the 51-file bundle plus changelog-merged notes."
tags: [release, packaging, git, gh, gplv2]
created: "2026-11-22T19:23:50.194Z"
updated: "2026-11-22T19:23:50.194Z"
---
Releasing busybox-static is: bump `VERSION`, write the `CHANGELOG.md` section, commit, tag `v$(cat VERSION)`, then `build-all.sh` → `pack-release.sh` → `gh release create` with the bundle. `pack-release.sh` proposes a busybox-derived tag (`v1.39.0-aac079e`); the project's own tag is `v0.4.0` and the asset filenames still carry the upstream stamp.

```text
  VERSION 0.4.0  +  CHANGELOG "## 0.4.0 — …"      (commit "release: 0.4.0")
        ↓
  ./build-all.sh          6 targets + lipo           ≈5 min
        ↓
  ./pack-release.sh       release/v1.39.0-aac079e/  51 files (binaries, patches,
                          configs, src tarball, SHA256SUMS, NOTES.md)
        ↓
  git tag -a v0.4.0 && git push origin main v0.4.0
        ↓
  gh release create v0.4.0 --repo rob-c/busybox-static \
     --title "busybox-static 0.4.0 (busybox 1.39.0.git)" \
     --notes-file release/v1.39.0-aac079e/NOTES-0.4.0.md \
     release/v1.39.0-aac079e/*
```

## Gotchas

- `pack-release.sh`'s final advice names the wrong tag for this repo. Use `v$(cat VERSION)`; the v0.3.0-dev release did the same, and its assets were likewise named `busybox-static-1.39.0-aac079e-*`.
- The release notes want both the changelog section and the generated legal/asset notes: `release/.../NOTES.md` covers licences and the asset table, so prepend the `## 0.4.0` section to it (as `NOTES-0.4.0.md`) rather than replacing it — GPLv2 §3 source-offer text must ship with the binaries.
- `release/` is gitignored; nothing about the bundle belongs in git, only the tag and `pack-release.sh`'s determinism.
- Downloaded assets arrive **non-executable** (`gh release download` drops the mode). `shasum -a 256 -c` on `SHA256SUMS` still verifies; `chmod +x` before running.

## Verification before tagging

`test.sh` 198 · `tests/agent-ops.sh` 1299 (1318 in `almalinux:9`) · `tests/streams.sh` 37 · `tests/timeout-resilience.sh` 50 · `tests/timeout-resilience-matrix.sh` 200 · patches `0004`/`0006`/`0008`/`0015` reverse-check · `busybox patchcheck` → `checked=15 bad=0`. After upload, re-download one binary and check `shasum -c`, then run `sh --timeout 1 -c 'sleep 3'` and expect exit 3.
