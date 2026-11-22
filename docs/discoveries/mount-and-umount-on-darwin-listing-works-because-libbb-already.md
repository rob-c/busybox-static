---
title: "mount/umount on Darwin: listing works because libbb already wraps getmntinfo"
kind: "discovery"
summary: "mount/umount work read-only on Darwin at 257 applets: listing needs no new code (libbb/mntent wraps getmntinfo), only MS_* defines plus three shims — and keep stubs quiet."
tags: [darwin, mount, umount, getmntinfo, mntent, readonly]
created: "2026-11-21T20:25:10.423Z"
updated: "2026-11-21T20:25:10.423Z"
---
`mount` and `umount` now build and run on Darwin (257 applets) as **read-only listing tools**. The listing needed no new code at all — `libbb/mntent.c` already implements `setmntent()`/`getmntent()` on `getmntinfo(3)` for `df` — so the whole job was getting the files to compile.

```text
 what failed to compile         fix
 <mntent.h> not found       ->  #ifdef HAVE_MNTENT_H guard (platform.h undefines it
                                for __APPLE__); libbb.h already declares the mntent API
 MS_RDONLY, MS_NOSUID,      ->  Darwin <sys/mount.h> has MNT_* not MS_*, so define
 MS_NODEV, MS_NOEXEC,           private values. Nothing reaches a kernel, so the
 MS_SYNCHRONOUS, MS_REMOUNT     actual bit numbers only need to be distinct
 getmntent_r undeclared     ->  copy the existing dietlibc branch: getmntent() +
                                memcpy into the caller's struct
 addmntent undeclared       ->  stub returning 1 ("failed"); /etc/mtab does not exist
 mount(2) / umount(2)       ->  stub setting errno = ENOSYS
```

## Do not print inside the stubs

The first version had each stub call `bb_error_msg(...)`, which produced two lines per failure because the busybox caller already reports the syscall result:

```text
umount: unmounting is not supported on Darwin (read-only build); use diskutil(8)…
umount: can't unmount /tmp/mnttest: Function not implemented
```

Set `errno = ENOSYS` and return -1 only; the caller's `can't unmount %s: %s` line is enough and it keeps the exit status correct (`mount` 255, `umount` 1, listing 0).

## Verified behaviour

```text
 $ busybox mount | head -3
 /dev/disk3s1s1 on / type apfs (ro,local)
 devfs on /dev type devfs (rw,nobrowse,local)
 /dev/disk3s6 on /System/Volumes/VM type apfs (rw,noexec,nobrowse,local)
 $ busybox mount | wc -l            -> 13
 $ busybox mount -t apfs | wc -l    -> 10   (fstype filter works)
 $ busybox mount /dev/disk9 /tmp/mnttest
 mount: mounting /dev/disk9 on /tmp/mnttest failed: No such file or directory
```

## README numbers drift

The `-pure` variants read 235 in the applet table while the real count is 253 — stale by several sessions. Recompute per target (`--list | wc -l`) rather than assuming `full − 1`; the pure build differs by *four* applets (nslookup and friends), not one. The "not ported" list also still claimed `mount`/`umount` were Linux-only after this change; check that list against the actual binary.
