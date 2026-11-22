---
title: "vmstat on Darwin, and the mapping for top/mpstat/ifconfig/route/lsblk/iostat"
kind: "discovery"
summary: "vmstat runs on Darwin (256 applets) via host_statistics + sysctl; the rest of the requested set is mapped to macOS sources — mpstat/top/ifconfig/route/fdisk need no dylib, lsblk/iostat need public IOKit."
tags: [darwin, vmstat, mpstat, top, ifconfig, route, lsblk, iostat]
created: "2026-11-21T19:09:25.985Z"
updated: "2026-11-21T19:09:25.985Z"
---
`vmstat` now runs on Darwin, taking the build to **256 applets** (Linux: 410). It was the cheapest of the requested set because its data collection is one array: `load_row(data_t data[NCOLS])` fills 18 slots and the existing `print_row`/`M_DPERCENT` code does the rest.

```text
 column sources on Darwin (all public, no new dylib)
 procs r   one KERN_PROC_ALL fetch, count p_stat == 2
 memory    bb_sysinfo(): host_statistics64 + hw.memsize
 swpd      sysctl vm.swapusage -> struct xsw_usage
 cpu us/sy/id   host_statistics(HOST_CPU_LOAD_INFO) ticks
 si so bi bo in cs   no macOS equivalent -> 0 (Linux also prints 0 when the counter is absent)
```

The trap: do not try to brace-match the old function body to wrap it in `#if`. `load_row` contains braces inside string literals, so a naive matcher inserted `#endif` in the wrong place and the body fell outside any function. Rename the original to `load_row_proc`, add `load_row_darwin`, and put a two-line dispatcher before the next function instead.

## The rest of the requested set: what each needs

Read-only first, ordered by effort. None of these is a shim.

| applet | macOS source | dylib | effort |
|---|---|---|---|
| `mpstat` | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` — per-CPU ticks, same maths as vmstat | none | small (~150 lines) |
| `top` | `host_statistics` totals + `proc_pidinfo(PROC_PIDTASKINFO)` per process (the procps layer already exists) | none | medium (~250), plus deciding what to do about the interactive modes |
| `ifconfig` | `getifaddrs(3)` for names/flags/addresses/netmask/broadcast; `ioctl(SIOCGIFMEDIA)` for media, `sysctl(NET_RT_IFLIST)` for MTU | none | medium — busybox's ifconfig is netlink-shaped, so a read-only printer is a new branch |
| `route` | `sysctl(NET_RT_DUMP)` over a `PF_ROUTE` socket, parsing `struct rt_msghdr` + sockaddrs | none | medium |
| `ip addr` / `ip link` / `ip route` | same two sources as above, mapped onto busybox's `ip` object API | none | medium-large |
| `fdisk -l` | plain `read()` of `/dev/rdisk*` + the MBR/GPT parsers already in `fdisk_gpt.c` | none | medium, and the safest read/write candidate of the storage group |
| `mount` (listing) | `getmntinfo(3)` — already used by this port's `libbb/mntent.c`, so the data is there | none | small (~80) |
| `lsblk` | DiskArbitration (`DASessionCreate`, `IOBSDNameMatching`) or IOKit `IOBlockStorageDriver` | DiskArbitration.framework / IOKit.framework, both public and present on every supported macOS | medium |
| `iostat` | the same IOKit disk statistics as lsblk plus `getfsstat` | IOKit.framework | medium |
| `udhcpc` | needs BPF (`/dev/bpf*`) to send/receive DHCP; macOS already runs `configd`/`ipconfig` | none, but a genuinely new client | large, low value |
| `mkfs.*`, `fsck` | Linux on-disk formats; macOS's equivalents are `newfs_*`/`fsck_*`, not busybox applets | — | do not port |

A public dylib is fine on every current macOS for **IOKit** and **DiskArbitration**; both are framework stubs in `/System/Library/Frameworks`, present since 10.x, so adding `-framework IOKit -framework DiskArbitration` to the Darwin link line in `build.sh` is safe. Nothing else in the list needs one.
