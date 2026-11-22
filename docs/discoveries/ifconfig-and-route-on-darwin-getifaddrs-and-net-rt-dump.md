---
title: "ifconfig and route on Darwin: getifaddrs and NET_RT_DUMP, and what cannot compile"
kind: "discovery"
summary: "ifconfig/route work read-only on Darwin at 259 applets: compile the Linux body out rather than patching it, read netmask sockaddrs by sa_len, and know rtentry is opaque so routes cannot be set."
tags: [darwin, ifconfig, route, getifaddrs, pf_route, netmask, rtentry]
created: "2026-11-21T20:39:38.106Z"
updated: "2026-11-21T20:39:38.106Z"
---
`ifconfig` and `route` now work read-only on Darwin (259 applets), both from one `getifaddrs(3)` pass and one `sysctl(NET_RT_DUMP)` pass. Three things bit: the Linux implementation cannot be patched to compile, BSD netmask sockaddrs lie about their family, and `struct rtentry` is opaque.

```text
 ifconfig  getifaddrs()      flags + ifa_addr per family + ifa_data (struct if_data)
                             -> mtu, byte counters
 route     sysctl NET_RT_DUMP over PF_ROUTE
                             -> rt_msghdr + sockaddrs, walked with RTAX_* bits
```

## Compile the Linux body out, do not patch it

`ifconfig.c` and `interface.c` use `ifr_netmask`, `ifr_ifindex`, `ifr_hwaddr`, `SIOCGIFINDEX` and `SIOCGIFHWADDR` — none exist in Darwin's `<net/if.h>`, and the errors cascade into unrelated-looking messages ("invalid application of `sizeof` to an incomplete type `const struct arg1opt[]`"). Two `#if` pairs are enough:

- `ifconfig.c`: `#if defined(__APPLE__)` provides a 15-line `ifconfig_main` that handles `[-a] [iface]` and dies on anything else; `#else` wraps the whole upstream implementation, and a final `#endif` closes it at EOF.
- `interface.c`: `#if !defined(__APPLE__)` wraps everything from the includes down to the Darwin helper, and `display_interfaces()` gets its own inner `#if/`#else`.

`libbb/in_ether.c` also needs `#define ETH_ALEN 6` — macOS has no `<net/ethernet.h>`.

## BSD sends netmask sockaddrs with sa_family == 0

Reading only `sa_family == AF_INET` prints `?` for every netmask. The mask bytes are present but the family is 0, so test `sa_len > offsetof(struct sockaddr_in, sin_addr)` instead, and treat a null/empty mask as `0.0.0.0` (that is the default route). Verified against `netstat -rn`:

```text
 100.64/10          -> ours 255.192.0.0
 127.0.0.0/8        -> ours 255.0.0.0
 100.100.100.100/32 -> ours 255.255.255.255
 default            -> ours 0.0.0.0
```

## struct rtentry is opaque, so route(8) cannot set routes

`<net/route.h>` forward-declares `struct rtentry` only — `sizeof` fails even with `-D_DARWIN_C_SOURCE`, so `SIOCADDRT`/`SIOCDELRT` are unusable. Wrap `INET_setroute`/`INET6_setroute` out and supply stubs that die with a pointer to the system `route(8)`; also `#define` the missing `RTF_REINSTATE`, `RTF_DEFAULT`, `RTF_ADDRCONF`, `RTF_CACHE`, `RTF_NONEXTHOP` **near the top of the file**, because they are referenced by a flag table above the setters (putting them with the stubs is too late and yields "undeclared identifier" at a line you did not touch).

## Watch the #endif pairing

Wrapping two functions in sequence, it is easy to emit `#endif` `#else` `#endif` in the wrong order and have the Darwin stubs compile only in the non-Darwin build — the symptom is `call to undeclared function 'INET_setroute'` at the *call* site, far from the edit. Check the region with `grep -n '^#if\|^#else\|^#endif'` after every wrap.
