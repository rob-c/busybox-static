---
title: "255/410 applets: the cheap tier is exhausted, here is the order to continue"
kind: "discovery"
summary: "readahead (F_RDADVISE) brings Darwin to 255 applets, exhausting the cheap tier: what remains needs netlink/host_statistics/OpenDirectory backends; sysctl is the next easiest."
tags: [darwin, readahead, applets, gap, backends]
created: "2026-11-21T18:43:20.019Z"
updated: "2026-11-21T18:43:20.019Z"
---
`readahead` now builds on Darwin, taking the build to **255 applets** (Linux: 410). It is the last applet in the "cheap" tier — everything remaining needs a new backend rather than a shim.

```text
 linux:  readahead(fd, 0, len)                    readahead(2)
 darwin: fcntl(fd, F_RDADVISE, &radvisory{offset,count})
```

## What the cheap tier contained

Two kinds of applet were recoverable, and both are now exhausted:

1. **Pruned by category, not dependency** — `watch`, `reset`, `free`, `uptime`, `fallocate`, `chpst`, `setuidgid`, `envuidgid`, `softlimit`: enabling them needed no code at all.
2. **Linux names, not Linux kernels** — `lsof` and `fuser` (libproc `PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`), `ping`/`ping6` (ten BSD ICMP defines, `struct ip`, `ip_hl`/`ip_ttl`, `SOL_IPV6`), `readahead` (`F_RDADVISE`), `free`/`uptime`/`ps` (a `struct sysinfo` filled from sysctls).

The rest are genuinely different kernel interfaces: `ifconfig`/`route`/`ip`/`udhcpc` want netlink and `AF_PACKET` where macOS has `PF_ROUTE` and BPF; `top`/`vmstat`/`iostat`/`mpstat` want `/proc/stat` where macOS has `host_statistics`; `mount`/`mkfs`/`fsck` want Linux `mount(2)` and `BLK*` ioctls; `su`/`passwd`/`adduser` want `/etc/shadow` where macOS has OpenDirectory; and `insmod`/`modprobe`, MTD, i2c, VT/framebuffer ioctls and `init`/`mdev` address subsystems macOS does not have.

## If someone continues

Pick one per session and expect build-error roulette, not a small diff. The order I'd try: `sysctl` (macOS has `sysctlbyname`, so name translation is the whole job), then `vmstat`/`top` over `host_statistics`, then `ifconfig` over `getifaddrs` + `PF_ROUTE` sockets. Each needs the same discipline that worked here: one applet at a time, build, and compare output against the Linux binary's.
