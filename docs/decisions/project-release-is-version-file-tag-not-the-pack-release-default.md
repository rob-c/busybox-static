---
title: "Release identity lives in VERSION, not in pack-release.sh's busybox-derived tag"
kind: "decision"
summary: "Release identity is VERSION (0.3.0-dev) plus CHANGELOG.md; pack-release.sh names its directory and tag after busybox, so pass v$(cat VERSION) to gh release create instead."
tags: [release, version, pack-release, gh, changelog]
created: "2026-11-22T11:48:31.263Z"
updated: "2026-11-22T11:48:31.263Z"
---
This repo ships a development release on top of upstream busybox, so it carries two versions: the busybox base (`1.39.0.git`, commit `aac079e`) and the project release in `VERSION` (`0.3.0-dev`). `./pack-release.sh` derives its directory and its suggested tag from the *busybox* side only, so the tag has to be overridden by hand when publishing.

```text
  VERSION ──► 0.3.0-dev                                  (project release)
  src/ git ─► 1.39.0.git + aac079e                        (busybox base)
  ./pack-release.sh ──► release/v1.39.0-aac079e/          (dir + notes + assets)
                          │
                          └─ gh release create v0.3.0-dev        <- override the tag
                             --title 'busybox-static 0.3.0-dev (busybox 1.39.0.git)'
                             --notes-file release/v1.39.0-aac079e/NOTES.md
                             release/v1.39.0-aac079e/*
```

## Publishing a new release

1. Bump `VERSION` and add a `CHANGELOG.md` section.
2. `./build-all.sh` (six targets + lipo), then `./test.sh dist/darwin-*/bin/busybox` for each Darwin target.
3. `./pack-release.sh` — writes `release/v<busybox>-<sha>/` with binaries, the **patched source tarball** (GPLv2 obligation), `.patch` files and per-target `.config`.
4. `gh release create v$(cat VERSION) ...` with the assets glob; do not accept `pack-release.sh`'s suggested `v1.39.0-aac079e` tag, which names only the busybox side.

## Gotcha

`gh auth status` and `docker ps` both hang on a degraded host, and both look like a hang in your own command. Check `gh auth status` with a timeout before assuming the release failed.
