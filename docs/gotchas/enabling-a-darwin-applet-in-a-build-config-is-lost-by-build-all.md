---
title: "Enabling a Darwin applet in a build config is lost by build-all.sh"
kind: "gotcha"
summary: "Ported applets must be enabled in build.sh EXTRA_CONFIG, not build/<target>/.config, because build-all.sh wipes build dirs; and never replace <sys/mount.h> with <sys/disk.h> unguarded."
tags: [build, kconfig, build-all, fdisk, darwin, reproducibility]
created: "2026-11-21T20:55:21.269Z"
updated: "2026-11-21T20:55:21.269Z"
---
Enabling a Darwin-ported applet by editing `build/<target>/.config` works until `build-all.sh` runs, because that script wipes every build directory first. Every ported applet therefore has to be enabled from `build.sh`'s Darwin `EXTRA_CONFIG` array, or a clean release build silently ships without it.

```text
 edit build/darwin-arm64/.config   -> ./build.sh darwin-arm64 keeps it (dir exists)
                                   -> ./build-all.sh loses it (rm -rf build/$t first)
 edit build.sh EXTRA_CONFIG        -> every target, every time
```

## What belongs in EXTRA_CONFIG

The Darwin block in `build.sh` now sets, in this order-sensitive sense, one entry per ported applet:

```text
 CONFIG_TOP=y  CONFIG_MPSTAT=y  CONFIG_MOUNT=y  CONFIG_UMOUNT=y
 CONFIG_IFCONFIG=y  CONFIG_ROUTE=y  CONFIG_FDISK=y
 CONFIG_FEATURE_TOP_INTERACTIVE=y  CONFIG_FEATURE_TOP_CPU_USAGE_PERCENTAGE=y
 CONFIG_FEATURE_TOP_CPU_GLOBAL_PERCENTS=y  CONFIG_FEATURE_TOP_DECIMALS=y
 CONFIG_FEATURE_FDISK_WRITABLE=n  CONFIG_FEATURE_FDISK_ADVANCED=n
```

The dependent `FEATURE_*` symbols are the trap: they default to `n` once their parent was ever disabled, so enabling `TOP` alone yields a `top` with no `CPU:` line and no `%CPU` column. Conversely `fdisk` needs `FEATURE_FDISK_WRITABLE=n`, because the writer calls `BLKRRPART`, which Darwin does not have.

## A framework include is not a drop-in replacement

`fdisk.c` had `#include <sys/mount.h>`, which on Linux transitively provides `BLKGETSIZE`/`BLKRRPART`. Swapping it for the Darwin `<sys/disk.h>` also removed the Linux path's only source of those constants, and the Linux build failed with `use of undeclared identifier 'BLKGETSIZE'`. Keep both, guarded:

```c
#if defined(__APPLE__)
# include <sys/disk.h>
#else
# include <sys/mount.h>   /* pulls in <linux/fs.h>: BLKGETSIZE, BLKRRPART */
#endif
```

## Why this is worth the long build

`build-all.sh` is the only command that proves the port is real: it rebuilds six targets from wiped directories and reports the file type, size, minimum macOS and dylib count of each. It caught both bugs above. Run it before claiming a port is done — a per-target `./build.sh` keeps a stale `.config` and will happily hide a missing applet or a Linux regression.
