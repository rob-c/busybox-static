---
title: "GitHub release assets lose the executable bit on download"
kind: "gotcha"
summary: "GitHub release assets lose the executable bit (0644 on download), so published binaries need chmod +x — and any verification step that runs a downloaded asset must chmod first or report a false failure."
tags: [github, releases, assets, chmod, docker, noexec, verification, busybox-static]
created: "2026-11-21T01:38:18.228Z"
updated: "2026-11-21T01:38:18.228Z"
---
GitHub release assets **lose the executable bit**. `gh release download` (and any browser download) yields mode `0644`, so a published busybox fails with `permission denied` until the user runs `chmod +x`. This was found by downloading the first release back and trying to run it in a container.

```mermaid
flowchart LR
    A["build: mode 0755"] --> B["gh release create"]
    B --> C["GitHub asset storage<br/>(no mode metadata)"]
    C --> D["download: mode 0644"]
    D --> E["exec: permission denied"]
    D --> F["chmod +x"] --> G["runs fine"]
```

## Consequences for the harness too

A verification step that downloads assets and executes them must `chmod +x` first, or it reports a false failure against a perfectly good artifact. The bytes are fine — only the mode is lost, and the SHA-256 is unaffected (it hashes content, not metadata).

## Second trap: bind-mounting a downloaded binary into a container

Docker Desktop on macOS presents bind-mounted files `noexec`, so `docker run -v $PWD/bb:/bin/busybox` fails with `permission denied` even after `chmod +x`. Copy the file into an image (`COPY busybox /bin/busybox`) instead; that also matches how the artifact will actually be used.

A `FROM scratch` image needs the applet symlink farm, otherwise bare `uname` fails with `not found`. Invoke applets through the binary (`/bin/busybox uname -m`) or copy the full `dist/<target>/` tree.

## What this means for users

The release notes must say `chmod +x` explicitly, and per-artifact `.sha256` sidecars should be published so one download can be verified without fetching the whole set.
