---
title: "`doctor --build` reports toolchain paths and tree layout"
kind: "instruction"
summary: "`doctor --build` prints tool paths (cc, clang, llvm-ar/nm/strip, zig, make, git) and whether src/build/patches exist, in text and JSON, because build failures usually read as a missing tool."
tags: [doctor, toolchain, build, json, section-14]
created: "2026-11-22T14:11:39.817Z"
updated: "2026-11-22T14:11:39.817Z"
---
`busybox doctor --build` reports the toolchain paths and tree layout that `build.sh` depends on, in both text and `--format json`. It exists because a build failure here almost always reads as "no such file" for a tool that simply is not on `PATH` — `llvm-ar`/`llvm-nm`/`llvm-strip` come from `/opt/homebrew/opt/llvm@22/bin` and are easy to lose across a shell restart.

```text
  build.sh failure "no such file: llvm-ar"
        │
        └─ doctor --build
             tool=llvm-ar path=-        <- the answer, in one line
             tree=src:yes build:yes patches:yes   <- and are you in the repo root?
```

```
$ busybox doctor --build
tool=cc path=/usr/bin/cc
tool=clang path=/usr/bin/clang
tool=llvm-ar path=-
tool=llvm-nm path=-
tool=llvm-strip path=-
tool=zig path=/opt/homebrew/Cellar/zig/0.17.1/bin/zig
tool=make path=/usr/bin/make
tool=git path=/usr/bin/git
tree=src:yes build:yes patches:yes
```

## What it checks, and what it does not

- Eight tools through the same `PATH` walk `doctor` already used for `--deps`: `cc`, `clang`, `llvm-ar`, `llvm-nm`, `llvm-strip`, `zig`, `make`, `git`. A missing tool prints `path=-`, never an error.
- `tree=` reports whether `src/Makefile`, `build/` and `patches/` exist *relative to the current directory* — i.e. whether you are in the repo root. It does not detect a stale `build/<target>/include/applets.h`.
- JSON keys: `build.tools.{…}` and `build.tree.{src,build,patches}`, additive to `platform`, `cwd`, `exe`, `shell`, `tmp`, `tmp_writable`, `deps`. Per `BUSYBOX-CONTRACT.md` §7, added fields are safe.

Ships in `patches/0008-agent-ops-run.patch`; regenerate that patch after editing `src/miscutils/doctor.c`.
