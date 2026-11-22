---
title: "Porting ip to Darwin needs a Kbuild gate, not just an #ifdef"
kind: "gotcha"
summary: "ip cannot be ported by wrapping ip.c: CONFIG_IP also builds libiproute's netlink objects, so a new Kconfig gate (or a separate ip-darwin.o) is required first."
tags: [darwin, ip, libiproute, netlink, kbuild, kconfig]
created: "2026-11-21T21:42:11.163Z"
updated: "2026-11-21T21:42:11.163Z"
---
`ip` is not ported. Two attempts stalled for a structural reason worth writing down, so the next person does not repeat the experiment.

```text
 CONFIG_IP=y  ->  networking/libiproute/Kbuild.src  ->  lib-$(CONFIG_IP) += libnetlink.o ...
                                                       ^ compiles netlink code that cannot
                                                         build against Darwin headers:
                                                         netpacket/packet.h, asm/types.h,
                                                         linux/if_arp.h
```

## Why wrapping ip.c is not enough

`ip.c` itself is easy to replace — guard the whole upstream body and provide a `ip_main` that prints `link`/`addr`/`route` from `getifaddrs(3)` and `sysctl(NET_RT_DUMP)`. The build still fails, because `CONFIG_IP` also pulls in eight objects from `networking/libiproute/` (`ip_common.h` includes `asm/types.h`; `ll_types.c` includes `linux/if_arp.h`; `iplink.c` includes `netpacket/packet.h`). None of those exist in the Darwin SDK.

Disabling the `FEATURE_IP_*` symbols is not sufficient either: `lib-$(CONFIG_IP) +=` is unconditional on `CONFIG_IP`, and several short-form applets (`ipaddr`, `iplink`, `iproute`) `select` those FEATURE symbols, so turning them off is not possible while keeping the applets.

## What it would need

Either of these, both of which touch the Kconfig surface:

1. **One new gate symbol** — e.g. `IP_BUILD_NETLINK`, default `y`, `depends on IP` — and change every `lib-$(CONFIG_FEATURE_IP_*)` line in `Kbuild.src` (plus the `CONFIG_IP` one) to be gated on it, with `build.sh` setting it to `n` on Darwin. On Linux the default keeps behaviour identical.
2. **A separate applet object** — a new `ip-darwin.o` built only when the gate is set, so upstream `ip.c`/`libiproute` are untouched.

Do **not** simply rename the kbuild keys to new undefined symbols: `lib-$(CONFIG_FOO)` with `FOO` undefined expands to `lib-` and silently drops every netlink object, which breaks the *Linux* link with undefined `do_ipaddr`/`do_iplink`. That mistake was made and reverted here.

## State

`src/networking/ip.c` and `src/networking/libiproute/Kbuild.src` are pristine (`git status` clean for both); `CONFIG_IP/IPADDR/IPLINK/IPROUTE` are back in `prune/darwin-off.txt`; the tree is at 262 Darwin applets with `./test.sh` 168/168 and the patch series reproducing `src/`.
