---
title: "Closing the Linux/Darwin applet gap: 236 to 251, and how to add a shim without breaking the patch series"
kind: "discovery"
summary: "Darwin went 236 to 251 applets: watch/reset/chpst/setuidgid/envuidgid/softlimit need no code, and a new sysinfo_compat.h header gives free/uptime/ps their data (loads are /2048, not /65536)."
tags: [darwin, applets, sysinfo, free, uptime, prune, patches]
created: "2026-11-21T17:55:39.769Z"
updated: "2026-11-21T17:55:39.769Z"
---
The Darwin build went from 236 to **251 applets** this round by taking the applets that were pruned *by category* rather than by dependency, plus one shim that unlocked three of them.

```text
prune/darwin-off.txt pruned by category
  watch, free, uptime, fallocate, reset, chpst, setuidgid, envuidgid, softlimit
        │                                    │
        ▼                                    ▼
  needed nothing             free/uptime/ps needed struct sysinfo
        │                                    │
   enabled directly                include/sysinfo_compat.h (statics)
```

## Enabled without code changes

`watch` (terminal escapes only), `reset`, `fallocate` (needs `posix_fallocate`, which macOS lacks — see below), and the runit helpers `chpst`, `setuidgid`, `envuidgid`, `softlimit`, which are pure `setuid`/`setrlimit`.

## The `sysinfo()` shim

`free`, `uptime` and `ps` all read `struct sysinfo`, which Linux fills in the kernel. Off Linux there is none, so `include/sysinfo_compat.h` defines a minimal struct and implements `bb_sysinfo()` from `KERN_BOOTTIME`, `hw.memsize`, `host_statistics64` and `getloadavg()`. It also provides `bb_posix_fallocate()` on top of `fcntl(F_PREALLOCATE)` for `fallocate`.

Two details that cost time:

* **Load averages are in 1/2048 units here**, not 1/65536: `uptime.c` prints them with `LOAD_INT(x) ((x) >> FSHIFT)` and `FSHIFT` is 11. Scaling by 65536 made the output 32x too large. With `* 2048` busybox `uptime` matches `/usr/bin/uptime` to the second decimal.
* **Put the shim in a new header, not in `platform.h`/`libbb/platform.c`.** Those two files are already owned by patches 0002 (the port) and 0003, so a 0004 hunk for them either duplicates their changes or fails to apply on top of them. A new file applies in any order and keeps the series separable. `free.c` also needs its `#if defined(__APPLE__)` branch around `parse_meminfo()`, which reads `/proc/meminfo`.

## Still not portable

`ip`/`ifconfig`/`route`/`ping` (netlink and `AF_PACKET`), `top`/`vmstat`/`iostat`/`mpstat`/`lsof`/`fuser` (`/proc/stat`, `/proc/PID/fd`), kernel modules, MTD, i2c, VT/framebuffer ioctls, `mount`/`mkfs`/`fsck`, DHCP, `syslogd`/`klogd`, `su`/`passwd` (OpenDirectory, no `/etc/shadow`). Each is either a different kernel API with no macOS counterpart or would need a new backend rather than a port.
