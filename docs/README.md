# Project notes

What this port learned, written down so nobody has to rediscover it. Each file
answers one question a new contributor — or a new agent on a new machine — would
otherwise get wrong.

Every file starts with YAML front matter (`title`, `kind`, `summary`, `tags`),
so the summary is usually all you need.

## Rules — hard constraints

- **[Publishing these binaries requires GPLv2 source+scripts; busybox is v2-only](rules/publishing-these-binaries-requires-gplv2-source-scripts-busybox.md)** — BusyBox here is GPLv2-only; publishing the binaries is allowed but each release must ship the patched source, build scripts and .configs, and never be labelled "or-later".

## Instructions — how work is done here

- **[Cutting a busybox-static release: the four steps that bite](instructions/cutting-a-busybox-static-release-the-four-steps-that-bite.md)** — Runbook for cutting a release: check upstream tags, reset+clean before re-applying patches, build-all.sh, pack-release.sh, then gh release create with the patched source tarball attached.

## Gotchas — things that break in non-obvious ways

- **[A nonzero exit is not a hang test: watchdog SIGKILLs create false passes](gotchas/a-nonzero-exit-is-not-a-hang-test-watchdog-sigkills-create.md)** — Assert interrupt promptness in milliseconds, not a nonzero exit — a watchdog SIGKILL also returns nonzero, so a hung process silently passes the test.
- **[Apple's ar fails on empty archives, breaking kbuild-style builds](gotchas/apple-s-ar-fails-on-empty-archives-breaking-kbuild-style-builds.md)** — Building busybox (or any kbuild-style project) on macOS fails with "ar: no archive members specified" — use llvm-ar instead of /usr/bin/ar.
- **[GitHub release assets lose the executable bit on download](gotchas/github-release-assets-lose-the-executable-bit-on-download.md)** — GitHub release assets lose the executable bit (0644 on download), so published binaries need chmod +x — and any verification step that runs a downloaded asset must chmod first or report a false failure.
- **[macOS binaries silently pin minos to the SDK version without -mmacosx-version-min](gotchas/macos-binaries-silently-pin-minos-to-the-sdk-version-without.md)** — macOS binaries need an explicit -mmacosx-version-min or clang pins minos to the SDK version and they refuse to launch anywhere older; use 11.0 arm64 / 10.13 x86_64.

## Discoveries — surprising behaviour, measured

- **[Gitignored artifacts still upload as release assets](discoveries/gitignored-artifacts-still-upload-as-release-assets-repo-is.md)** — Release assets are stored outside git, so .gitignore'd build outputs still upload fine; the repo holds no artifacts but publishes them as downloads.
- **[Static macOS binaries are impossible: no static libc, and arm64 kills dyld-free executables](discoveries/static-macos-binaries-are-impossible-no-static-libc-exists-only.md)** — Cannot build a static macOS binary: no static libc exists, libc isn't a file, clang/gcc/zig all refuse, and arm64 kills dyld-free executables even when signed; the floor is libSystem-only.

## Nothing here is a substitute for the code

Where a note and the source disagree, the source wins. Every claim in these
notes was measured on the machine that wrote it — see `../README.md` for the
evidence and `../stress.sh --selftest` to re-check the test harness itself.
