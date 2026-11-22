---
title: "`snapshot`: hash a tree and diff two snapshots (patch 0013)"
kind: "instruction"
summary: "`busybox snapshot -d DIR` writes sha256/size/path lines and `--diff A B` reports added/removed/changed (exit 1 on difference); avoid a `+` optstring or `--format json` is silently dropped."
tags: [snapshot, applet, patch-0013, sha256, agent-features]
created: "2026-11-22T14:49:35.463Z"
updated: "2026-11-22T14:49:35.463Z"
---
`busybox snapshot` records the sha256 of every regular file under a directory and diffs two such records, so a harness can say "these files changed" without git and without /proc or inotify. Ships as `patches/0013-agent-ops-snapshot.patch`.

```text
  snapshot -d DIR [-o FILE]        sha256 size path, sorted  ──►  s1
  (edit files)
  snapshot -d DIR                  ──►  s2
  snapshot --diff s1 s2            removed a / changed b / added c   exit 1 if any differ
```

```
$ snapshot -d t
2c8b08da…c806 4 a
27dd8ed4…00a5a 4 b

$ snapshot --diff s1 s2
removed a
changed b
added c
added=1 removed=1 changed=1        # exit 1

$ snapshot --diff s1 s2 --format json
{"schema":1,"status":"ok","changes":[{"kind":"removed","path":"a"},…],"added":1,"removed":1,"changed":1}
```

## Details that matter

- Hashing uses libbb's own sha256 (`sha256_begin/hash/end` + `bin2hex`) — no OpenSSL dependency, identical on Darwin and Linux. The walk is `lstat`-based, depth-capped at 32, and skips `.`/`..` only (dotfiles *are* included).
- Exit 1 on `--diff` means "differences found", not "error" — inside the contract's 0/1/2/3 range, and mirrors `diff`'s convention.
- **Options must not be hidden behind a `+` optstring here.** `--diff A B --format json` needs `getopt32long(argv, "d:o:D:F:", …)` (permuting); with a `+` prefix parsing stops at `B`, so `--format json` is silently ignored and the JSON consumer gets an empty read.
- `non-regular` files (FIFOs, sockets, devices) are skipped rather than hashed, so a snapshot never blocks on a FIFO.
- Entry point is `snapshot_main_main`; `CONFIG_SNAPSHOT=y` goes in both `EXTRA_CONFIG` blocks, and a first build after adding it may need a second `./build.sh` run while `Config.in` regenerates.
