---
title: "What networking mutation Darwin actually allows, including routes"
kind: "discovery"
summary: "Darwin has SIOCSIFADDR/MTU/FLAGS/AIFADDR/LLADDR and a working PF_ROUTE socket, so writable route/ifconfig/ip are feasible with root; SIOCSARP and VLAN headers are absent."
tags: [darwin, networking, ioctl, pf_route, rtm_add, ifconfig, route, ip]
created: "2026-11-21T22:02:20.896Z"
updated: "2026-11-21T22:03:06.134Z"
---
A previous doc in this repo says adding routes on Darwin is impossible because `struct rtentry` is opaque. **That is wrong.** Only the Linux-style `ioctl(SIOCADDRT, struct rtentry *)` path is blocked; the BSD/PF_ROUTE message path that macOS `route(8)` itself uses works fine. Measured on this machine:

```text
 socket(PF_ROUTE, SOCK_RAW, 0)   -> ok
 RTM_GET write (no root)         -> ok, 108 bytes
 RTM_ADD / RTM_DELETE / RTM_CHANGE / RTM_IFINFO -> all defined
```

## The full writable surface, compiled not guessed

A probe that includes `<sys/sockio.h>`, `<net/if.h>`, `<net/if_media.h>`, `<net/route.h>` confirms these are present:

| ioctl | lets busybox do |
|---|---|
| `SIOCSIFFLAGS` | `ifconfig up/down`, `ip link set up/down` |
| `SIOCSIFMTU` | `mtu N` |
| `SIOCSIFADDR` / `SIOCSIFNETMASK` / `SIOCSIFBRDADDR` / `SIOCSIFDSTADDR` | set address, netmask, broadcast, pointopoint |
| `SIOCAIFADDR` / `SIOCDIFADDR` | **aliases** — `ip addr add/del`, `ifconfig alias` |
| `SIOCSIFLLADDR` | `hw ether` / `ip link set address` |
| `SIOCSIFMEDIA` | `media` / duplex selection |
| `SIOCSIFPHYADDR` | tunnel endpoints |

Absent from the SDK: `SIOCSIFNAME` (no interface rename), `SIOCSARP`/`SIOCDARP`/`SIOCGARP` (the probe defines `struct arpreq` — 36 bytes — but not the ioctls), and `net/if_vlan_var.h` / `net/if_bridgevar.h` are missing entirely. So ARP writes and VLAN/bridge config cannot use those ioctls: ARP entries go through the routing socket (`RTM_ADD` with a link-layer `RTA_GATEWAY`), and VLAN/bridge must shell out to `ifconfig`.

## Privilege, not capability, is the gate

Every mutating ioctl returns `EPERM` for a normal user — exactly like Linux, where `ifconfig` needs root. `/dev/bpf*` exists but is `crw------- root:wheel`, so a BPF-based DHCP client needs root too. Nothing here is architecturally blocked.

## What that is worth in applets

Feasible with the ioctl set above, no new dylib: **writable `ifconfig`** (up/down, mtu, address/netmask/broadcast, alias add/del, hw ether, media) — everything except renaming; **`ip link set`**, **`ip addr add|del`**; **`route add|del`** and **`ip route add|del|change`** via the routing socket. Requires root.

Feasible but larger: `udhcpc`/`udhcpd` over BPF (root), `ip tuntap` via `utun`/`PF_SYSTEM`, `arp -s/-d` via `RTM_ADD` with an `AF_LINK` gateway.

Not feasible: `ip rule` (macOS has no policy routing), `tc` (no qdiscs), `ifenslave` (no bonding), `slattach` (no SLIP), and VLAN/bridge as applets that talk to the kernel directly.

**Consequence for the read-only guards already shipped:** `ifconfig`, `route` and `ip` currently die with "only listing is supported on Darwin". Those guards are conservative, not structural — the plumbing underneath them exists.
