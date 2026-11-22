---
title: "ip on Darwin: one Kconfig gate plus getifaddrs and NET_RT_DUMP"
kind: "discovery"
summary: "ip works read-only on Darwin at 263 applets: add a CONFIG_IP_BUILD_NETLINK gate (default y, off for Darwin) so libiproute's netlink objects are skipped — never by renaming kbuild keys to undeclared symbols."
tags: [darwin, ip, libiproute, kbuild, kconfig, getifaddrs, pf_route]
created: "2026-11-21T21:57:27.981Z"
updated: "2026-11-21T21:57:27.981Z"
---
`ip` now works read-only on Darwin (263 applets) as `ip addr`, `ip link` and `ip route`. It needed **one** build-system change, not new porting: `CONFIG_IP=y` unconditionally pulled in the rtnetlink backends.

```text
 before:  lib-$(CONFIG_IP) += libnetlink.o ll_*.o rt_*.o ...   <- compiled on Darwin,
                                                               and cannot be: asm/types.h,
                                                               linux/if_arp.h,
                                                               netpacket/packet.h
 after:   lib-$(CONFIG_IP_BUILD_NETLINK) += ...                <- new Kconfig symbol,
                                                                 default y, disabled for
                                                                 Darwin in prune/darwin-off.txt
```

The new symbol lives in `networking/ip.c`'s own `//config:` block, so no separate Config file is needed:

```text
 //config:config IP_BUILD_NETLINK
 //config:	bool "Build the libiproute netlink backends"
 //config:	default y
 //config:	depends on IP || IPADDR || IPLINK || IPROUTE || IPRULE || IPTUNNEL || IPNEIGH
```

## Do not rename kbuild keys to invented symbols

The tempting shortcut — rewriting `lib-$(CONFIG_IP)` to some undeclared name — makes kbuild expand the block to `lib-`, silently dropping every netlink object and breaking the **Linux** link with undefined `do_ipaddr`. Declare the symbol and disable it per platform instead.

Verified on both sides after `./build-all.sh`:

```text
 build/linux-amd64/networking/libiproute/*.o   16 objects
 build/darwin-arm64/networking/libiproute/*.o   1 object (built-in.o, empty archive)
```

`FEATURE_IP_ADDRESS`, `_LINK`, `_ROUTE`, `_TUNNEL`, `_RULE`, `_NEIGH` and `_LINK_CAN` must also be disabled for Darwin: they default to `y` whenever `IP` is on, and each pulls its own object set.

## The Darwin implementation

Same two sources as `ifconfig` and `route`: `getifaddrs(3)` for `addr`/`link`, `sysctl(NET_RT_DUMP)` over `PF_ROUTE` for `route`. It needs no framework, so `ip` stays **inside the `-pure` builds** (260 applets there), unlike `iostat`/`lsblk`.

```text
 $ busybox ip route
 default via 192.168.1.1 dev en0 proto static
 100.64.0.0/10 dev utun4
 100.64.0.3 via 100.64.0.3 dev utun4
 $ busybox ip addr
 1: lo0: <UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
     inet 127.0.0.1/8 scope host
     inet6 ::1/128 scope global
```

Two details worth keeping: print the flag list through a comma-aware helper, because flags are not a fixed prefix — `gif0` has `MULTICAST` but not `UP`, and naive code emitted `<,MULTICAST>`. And remember a BSD netmask sockaddr may carry `sa_family == 0`, so derive the prefix length from `sa_len`, not the family.
