---
title: "Darwin df ignores its path because APFS firmlinks share st_dev"
kind: "gotcha"
summary: "df ignored its path argument on macOS because APFS firmlinks share st_dev; fix with a longest-prefix mount match that copies strings out of getmntent's shared struct."
tags: [darwin, df, apfs, firmlink, getmntent, find_mount_point, patches]
created: "2026-11-22T01:31:44.560Z"
updated: "2026-11-22T01:31:44.560Z"
---
On macOS, `df <path>` reported the **root filesystem for every path** — `df /System/Volumes/VM` printed the `/` row. The cause is that `find_mount_point()` matched the mount table by `st_dev`, and APFS firmlinks make `/` and `/System/Volumes/Data` report the *same* device number, so the first table entry always won.

```text
 before:  df /System/Volumes/VM  ->  /dev/disk3s1s1 ... /
 after:   df /System/Volumes/VM  ->  /dev/disk3s6 ... /System/Volumes/VM
```

## The fix is a longest-prefix match, and it must copy strings

Under `#if defined(__APPLE__)`, before falling back to device matching, walk the mount table and keep the entry whose `mnt_dir` is the **longest prefix** of `realpath(path)`, requiring the prefix to end on a path boundary (`want[l]` is `/` or NUL).

Two ways to get this wrong, both of which produced worse output than the bug:

**1. Keeping a pointer to the entry.** `getmntent()` returns one reused static `struct mntent`, so storing `best = e` leaves you holding the *last* row of the table — every path then reported `/Volumes/SidePulse`. Copy `mnt_dir`/`mnt_fsname` into static buffers at the moment the entry becomes best.

**2. Returning pointers into automatic storage.** The buffers that the returned struct points at must be `static`, or they dangle the moment the function returns and every caller sees an empty mount point (`df: : No such file or directory`).

## Regenerating the patch series

`libbb/find_mount_point.c` is already touched by patch 0002, so putting this change in 0004 makes `git apply` fail — 0004's diff (taken against upstream) duplicates 0002's hunks. It lives in its own **0005-darwin-df-mount-resolution.patch** instead, whose pre-image must be generated from a *real* tree with 0001–0004 applied, not by subtracting text from the working copy (subtraction left an extra blank line and the patch was rejected at `@@ -45,7`).

## Still not matching macOS

`df /` reports **container-wide** usage (1.3T used, 71%) because it reads raw `statvfs`, while `/bin/df` reports **per-volume** usage for the sealed system snapshot (13Gi, 3%). Both agree on total and available. Matching Apple exactly needs `getattrlist(ATTR_VOL_SPACEUSED)`, which busybox does not currently call; the same caveat applies to every APFS volume in the container.
