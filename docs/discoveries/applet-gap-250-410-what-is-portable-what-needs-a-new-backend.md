---
title: "Applet gap 250/410: what is portable, what needs a new backend, what cannot exist"
kind: "discovery"
summary: "Darwin has 250 of Linux's 410 applets; the remaining ~160 split into different-kernel-API (lsof/fuser cheapest), different-data-source (OpenDirectory), and no-counterpart (modules, MTD, VT ioctls) — with the new-header rule for shims."
tags: [darwin, applets, gap, porting, lsof, sysinfo]
created: "2026-11-21T18:00:23.061Z"
updated: "2026-11-21T18:00:23.061Z"
---
The Darwin build carries **250 applets** (Linux: 410). The remaining ~160 are not a backlog of ports — each needs a different kernel API. This is the triage, with the cheapest next step named.

```text
 250 darwin  ──────────────────────────────────────────────  410 linux
              │ ported by category: watch reset free uptime
              │ fallocate chpst setuidgid envuidgid softlimit
              │ ps pgrep pkill pstree pidof (sysctl)
              ▼
        ~160 left, in three buckets
        A  different kernel API     ping ifconfig route ip udhcpc top vmstat
        B  a macOS backend          su passwd adduser login (OpenDirectory)
        C  hardware that isn't there  insmod mtd i2c vt/fb ioctls init mdev
```

## Bucket A: same idea, different API (portable in principle)

* `lsof` — **cheapest**, ~80 lines in `procps/lsof.c`: `proc_pidinfo(PID, PROC_PIDLISTFDS)` to enumerate descriptors, `proc_pidfdinfo(PID, fd, PROC_PIDFDVNODEPATHINFO)` to get a vnode's path. My first attempt wrapped the file's `#if`/`#else` badly (the `#endif` landed inside the new function), so it was reverted; the code shape is straightforward.
* `fuser` — same enumeration plus a scan of `/proc/net/TCP` for `port/proto` arguments; the file-descriptor half is the same work as `lsof`, the network half needs `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`.
* `ping` / `ping6` — `SOCK_DGRAM`/`SOCK_RAW` ICMP works on macOS for root, but `ping.c` uses `SO_BINDTODEVICE`, `IP_PKTINFO` and Linux `struct icmp` details that need `#ifdef`s; expect build-error roulette, not a small diff.
* `ifconfig` / `route` / `ip` — Linux netlink (`rtnetlink`) versus macOS routing sockets (`PF_ROUTE`) plus `getifaddrs()`; a rewrite of the backend, not a port.
* `top` / `vmstat` / `iostat` / `mpstat` — `/proc/stat`, `/proc/loadavg`, per-CPU counters. macOS exposes `host_statistics`/`processor_info`; different shapes again.

## Bucket B: different data source

`su`, `passwd`, `adduser`, `chpasswd`, `login` read `/etc/shadow` and `/etc/passwd`; macOS accounts come from OpenDirectory and `dscl`. `CONFIG_USE_BB_PWD_GRP` is already off for this reason (`whoami` had said "unknown uid 504" until it was).

## Bucket C: no counterpart

Kernel modules (`insmod`/`modprobe`/`lsmod`), MTD (`nandwrite`, `ubi*`), i2c, framebuffer and VT ioctls, `init`/`mdev`, `hdparm`, `setserial`. These talk to Linux kernel subsystems that do not exist on Darwin at all.

## Rule learned while doing this

Adding a shim must go in a **new file** (`include/sysinfo_compat.h` for `free`/`uptime`/`ps`), never in `include/platform.h` or `libbb/platform.c`: those are owned by patches 0002/0003, and a 0004 hunk for them either duplicates their changes (a second `strverscmp()`) or fails to apply on top of them.
