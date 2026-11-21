---
title: "Gitignored artifacts still upload as release assets"
kind: "discovery"
summary: "Release assets are stored outside git, so .gitignore'd build outputs still upload fine; the repo holds no artifacts but publishes them as downloads."
tags: [github, releases, artifacts, gitignore, gh-cli, busybox-static]
created: "2026-11-21T00:39:11.667Z"
updated: "2026-11-21T00:39:11.667Z"
---
`rob-c/busybox-static` holds source, patches and scripts only — zero artifacts in git — yet build outputs are still publishable. The reason they coexist: git tracking and release assets are separate storage.

```mermaid
flowchart LR
    A["working tree"] --> B{git add}
    B -->|"not ignored"| C["git history<br/>14 files, ~190 KB"]
    B -->|"ignored: build/ dist/<br/>release/ src/"| D["never committed"]
    A --> E{"gh release create path"}
    E -->|"any path, ignored or not"| F["release asset<br/>downloaded by users"]
    D -.->|"same files"| E
```

So `.gitignore` does **not** block uploads — a common wrong assumption. `gh release create` takes filesystem paths, not tree paths, so `dist/darwin-universal/bin/busybox` uploads fine while being ignored by git. Verified by attaching both a gitignored binary (1485968 B) and `release/...-src.tar.gz` (3348162 B) to a draft release.

## Repo visibility

Start private (reversible) and flip when ready; assets carry over, no re-upload:

    gh repo edit rob-c/busybox-static --visibility public

**Private repos require authentication to download release assets**, so a
private repo cannot actually share binaries. The repo was created private and
made public once the release was verified.

## Quirks

`gh release create <tag>` where the tag does not exist yet produces an **untagged** draft (URL contains `untagged-...`); `--cleanup-tag` then fails with `HTTP 422: Reference does not exist`. Harmless, but do not read it as a broken upload.

Repo stays small because `src/` (24 MB upstream clone) is ignored; the GPL source obligation is met by the attached source tarball, not by tracking upstream history.
