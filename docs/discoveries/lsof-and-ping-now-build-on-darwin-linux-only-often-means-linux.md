---
title: "lsof and ping now build on Darwin: Linux-only often means Linux names"
kind: "discovery"
summary: "lsof (libproc) and ping/ping6 (10 BSD-name defines) now build on Darwin: 253 applets. ping is root-only by design, same as Linux; fuser is next (needs PROC_PIDFDSOCKETINFO)."
tags: [darwin, lsof, ping, applets, icmp, libproc]
created: "2026-11-21T18:16:14.006Z"
updated: "2026-11-21T18:16:14.006Z"
---
`lsof` and `ping`/`ping6` now work on Darwin, taking the build to **253 applets** (Linux: 410). Both needed only naming/API shims, not new backends — the lesson is that "Linux-only" in the prune list often means "Linux names", not "Linux kernel".

```text
 ping.c build errors on Darwin              fix
 ICMP_DEST_UNREACH … ICMP_ADDRESSREPLY  →  BSD names: ICMP_UNREACH … ICMP_MASKREPLY
 struct iphdr                           →  #define iphdr ip
 ip->ihl / ip->ttl                      →  #define ihl ip_hl / #define ttl ip_ttl
 SOL_IPV6                               →  #define SOL_IPV6 IPPROTO_IPV6
```

## lsof

Rewrite the file rather than patch around its `#if`: `procps/lsof.c` is small enough (78 lines) that a whole-file replacement with `#if defined(__APPLE__) … #else … #endif` is safer than inserting into the middle — my first attempt put the `#endif` inside the new function and produced `#else without #if`.

Darwin implementation: `proc_pidinfo(pid, PROC_PIDLISTFDS, …)` for the descriptor list, then `proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, …)` for a vnode's path. Sockets and pipes are skipped, which matches the `/proc` version (it only printed resolvable symlinks). Verified: `echo hi > /tmp/lt.txt; busybox sh -c 'exec 3</tmp/lt.txt; busybox lsof'` lists fd 3 with the path.

## ping

Ten compat defines at the top of `networking/ping.c` and it compiles. It then reports `ping: permission denied (are you root?)` because raw ICMP sockets need root and these binaries are **not setuid** — identical to the Linux build, where busybox `ping` also needs `CAP_NET_RAW`. So the behaviour is at parity; it is not a port bug. (Could not verify as root here: no passwordless `sudo`.)

## Still not portable

`fuser` (needs `PROC_PIDFDSOCKETINFO` on top of the lsof enumeration — next cheapest), `ifconfig`/`route`/`ip`/DHCP (netlink/`AF_PACKET` versus `PF_ROUTE`), `top`/`vmstat`/`iostat`/`mpstat` (`/proc/stat` versus `host_statistics`), `mount`/`mkfs`/`fsck`, `syslogd`/`klogd`, and `su`/`passwd`/`adduser` (OpenDirectory, no `/etc/shadow`).
