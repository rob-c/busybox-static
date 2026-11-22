---
title: "Writable networking on Darwin: ifconfig, route and ip"
kind: "discovery"
summary: "ifconfig, route and ip are now writable on Darwin via SIOCS* ioctls and PF_ROUTE; watch the 16-byte ifr_addr, the -net to #net rewrite, and BSD-only headers breaking Linux."
tags: [darwin, ifconfig, route, ip, ioctl, pf_route, writable, sockaddr_dl]
created: "2026-11-21T22:33:38.397Z"
updated: "2026-11-21T22:33:38.397Z"
---
`ifconfig`, `route` and `ip` are now **writable** on Darwin, using the ioctl and routing-socket paths measured earlier. Everything requires root and fails with `EPERM` otherwise, exactly like the Linux build.

```text
 ifconfig  up/down          SIOCSIFFLAGS (read-modify-write)
           mtu N            SIOCSIFMTU
           addr[/pfx]       SIOCSIFADDR (+ SIOCSIFNETMASK)
           alias / -alias   SIOCAIFADDR / SIOCDIFADDR
           netmask/broadcast/pointopoint  SIOCSIFNETMASK / BRDADDR / DSTADDR
           hw ether MAC     SIOCSIFLLADDR
 route     add|del [-net|-host] DEST [gw GW] [dev IF] [netmask M]   PF_ROUTE
 ip        link set up|down|mtu|address   addr add|del   route add|del|via/ dev
```

## Three traps, all found by building

**1. `ifr_addr` is 16 bytes; `sizeof(struct sockaddr_dl)` is 20.** Writing a full `sockaddr_dl` into `ifr.ifr_addr` overruns `ifr_ifru` and dies with `EXC_BREAKPOINT` (a `Trace/BPT trap: 5`). Size it to the data actually needed:

```c
memset(&ifr.ifr_addr, 0, sizeof(ifr.ifr_addr));
sdl->sdl_len = offsetof(struct sockaddr_dl, sdl_data) + 6;   /* 14, fits */
```

**2. `route_main` rewrites `-net`/`-host` to `#net`/`#host` in argv** before any handler runs ("We remap '-' to '#' to avoid problems with getopt", route.c:105). A Darwin handler that only compares against `-net` sees `#net` and rejects the argument. Accept both spellings.

**3. `<net/if_dl.h>` is BSD-only.** Adding it unconditionally to `route.c` broke the *Linux* build (`fatal error: 'net/if_dl.h' file not found`); it belongs inside the `#if defined(__APPLE__)` block, like `<sys/disk.h>` and `<sys/mount.h>` before it.

## Verifying a mutating path without root

No privileged account is available here, so success cannot be observed. What *can* be checked — and is — that each argument form reaches **its own** ioctl or routing-socket write and reports that specific operation:

```text
 $ busybox ifconfig lo0 mtu 9000        -> can't set mtu on lo0: Operation not permitted
 $ busybox ifconfig lo0 alias 127.0.0.2 -> can't add 127.0.0.2 on lo0: Operation not permitted
 $ busybox route add -net 10.0.0.0/8 gw 192.168.1.1 -> add 10.0.0.0: Operation not permitted
 $ busybox ip addr add 10.9.9.9/24 dev lo0        -> can't add 10.9.9.9/24 on lo0: Operation not permitted
 $ busybox ip route add 10.0.0.0/8 via 192.168.1.1 -> add 10.0.0.0/8: Operation not permitted
```

Each message names a different syscall, which is how the parse-to-ioctl mapping was confirmed without root. A distinct message per operation is worth the extra lines for exactly this reason — a generic "only listing is supported" hid all of it.

## Not attempted

`media` is parsed but not applied (`SIOCSIFMEDIA` needs media words mid-parse). IPv6 route add/del is refused on Darwin. ARP writes still need the routing socket with an `AF_LINK` gateway, and `udhcpc` still needs a BPF client.
