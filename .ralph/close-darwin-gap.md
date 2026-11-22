# Close Darwin applet gap: mpstat/top/vmstat/iostat + networking + storage

Implement Darwin backends for the requested applets, one per iteration, with build+test verification.

## Goals
- mpstat, top, vmstat, iostat on Darwin via host_statistics / host_processor_info / IOKit
- ip, route, ifconfig (read-only) via getifaddrs + NET_RT_DUMP/PF_ROUTE
- mount, lsblk, fdisk read-only (getmntinfo, IOKit, /dev/rdisk)
- Keep Linux behaviour unimpacted; all changes behind #if defined(__APPLE__)

## Checklist
- [x] Raise maxGateTurns to 20 and inspect current vmstat/mpstat wiring
- [x] mpstat: Darwin backend (host_processor_info PROCESSOR_CPU_LOAD_INFO + KERN_BOOTTIME)
- [x] top: Darwin backend (host_statistics + proc_pidinfo PROC_PIDTASKINFO)
- [x] mount listing: getmntinfo(3) backend (+ umount, read-only)
- [x] lsblk: IOKit IOMedia backend (shares iostat's dylibs)
- [x] iostat: IOKit disk stats backend (IOBlockStorageDriver)
- [x] fdisk -l: /dev/diskN enumeration + DKIOCGETBLOCK{SIZE,COUNT}
- [x] ifconfig read-only: getifaddrs + if_data
- [x] route read-only: sysctl NET_RT_DUMP via PF_ROUTE
- [x] ip addr/link/route read-only
- [ ] udhcpc assessment + mkfs/fsck assessment docs
- [ ] Regenerate patches, build-all.sh, test.sh, README

## Verification
- 2026-11-21 iteration 1: mpstat WORKS. Root cause of the "can't open /proc/stat" was get_cpu_count() in libbb/get_cpu_count.c (not mpstat.c). Fixed with sysctlbyname("hw.ncpu"). Also guarded all four /proc readers in mpstat.c with delegating early returns, and clamped host_processor_info's ncpu (returns 72 = ncpu*4 on this machine, while ncpu_nat=18).
- Commands: `./build.sh darwin-arm64` rc=0; `dist/darwin-arm64/bin/busybox --list | wc -l` = 254; `busybox mpstat` prints 18 CPUs + all row; `mpstat -P ALL`, `-u`, `-I SUM`, `1 1` all OK; `vmstat` unaffected; `./test.sh dist/darwin-arm64/bin/busybox` = 168 passed 0 failed.
- `./build-all.sh` rc=0, 6 targets + universal; darwin 254 applets, pure 253. Linux binaries are musl x86_64/aarch64 and cannot run on this arm64 Mac (expected).
- patches/0004 regenerated via /tmp/genpatch4_new.py with procps/mpstat.c + libbb/get_cpu_count.c added (75889 bytes, 24 dirs). Reproducibility verified: fresh clone + apply 0001-0004 + `diff -r --exclude=.git` => REPRODUCES (0 diff lines).
- mount/umount were attempted and reverted: Darwin's <sys/mount.h> has no MS_RDONLY/MS_REMOUNT and mount(2) has an incompatible signature; needs a dedicated read-only listing branch, not a shim. Deferred.

### iteration 2: top done
- get_jiffy_counts -> host_statistics(HOST_CPU_LOAD_INFO); parse_meminfo -> hw.memsize + host_statistics64 + vm.swapusage (cached = inactive+purgeable, buff = purgeable+wire); loadavg -> getloadavg; xchdir("/proc") guarded.
- libbb/procps.c Darwin scan now fills utime/stime/rss/vsz from proc_pidinfo(PROC_PIDTASKINFO) (ns -> bb_clk_tck ticks; bytes -> KB) and STAT from PROC_PIDTBSDINFO.
- Enabled FEATURE_TOP_INTERACTIVE / CPU_USAGE_PERCENTAGE / CPU_GLOBAL_PERCENTS / DECIMALS in build/darwin-arm64/.config. These must be set by hand (sed + `make O=build/<t> oldconfig`); a plain build.sh run reset them to n. Without them top prints no CPU line and no %CPU column.
- sysinfo_compat.h now fills totalswap/freeswap from vm.swapusage, so `free` shows Swap: 3145728 total / 2259456 used / 886272 free.
- Verified: `--list | wc -l` = 255; `top -b -n1` -> `Mem: 100038048K used, 34179680K free, 0K shrd, 11982624K buff, 41203264K cached` + `CPU: 36.3% usr 4.7% sys 0.0% nic 58.9% idle` + `Load average: 15.91 16.63 19.59` + per-process %RSS/%CPU; `-n2` second frame OK; `./test.sh` 168 passed 0 failed.
- patches/0004 regenerated (83547 bytes, 25 dirs) including procps/top.c; fresh clone + apply 0001-0004 => REPRODUCES.
- README updated: new wiki-style row describing vmstat/mpstat/top; the Darwin applet count in the table stays 255.
- Known limit recorded in docs/discoveries/top-on-darwin-*: macOS reports p_stat==SRUN for every process (verified against /bin/ps on a `sleep 30`; BSDINFO and SHORTBSDINFO both return 2), so STAT shows R where Apple's ps shows S. No public API distinguishes them.


## Notes
- vmstat, mpstat and top are all done and verified (255 applets).
- Next: mount listing via getmntinfo (needs a dedicated read-only branch, NOT a shim: Darwin <sys/mount.h> has no MS_RDONLY/MS_REMOUNT and mount(2) has a different signature).
- Then iostat (IOKit), lsblk (IOKit/DiskArbitration, needs -framework flags), fdisk -l (read /dev/rdisk*), then networking.
- Reproduce any of this with: `./build.sh darwin-arm64 && dist/darwin-arm64/bin/busybox --list | wc -l && ./test.sh dist/darwin-arm64/bin/busybox`.

### iteration 3: mount + umount done
- Read-only listing via libbb/mntent.c (getmntinfo), the layer df already used; no new data layer needed.
- Compile fixes: HAVE_MNTENT_H guard; private MS_* and MNT_FORCE defines (Darwin has MNT_* not MS_*); getmntent_r shim using the dietlibc pattern; addmntent stub; mount(2)/umount(2) stubs returning ENOSYS.
- Stubs stay quiet (set errno only) so the caller prints one line. Exit codes: mount failure 255, umount failure 1, mount listing 0.
- Verified: `busybox mount` -> 13 entries (`/dev/disk3s1s1 on / type apfs (ro,local)`); `mount -t apfs | wc -l` = 10; `mount /dev/disk9 /tmp/mnttest` -> "failed: No such file or directory"; `umount /nope` -> "can't unmount /nope: Function not implemented".
- Applets 255 -> 257 (mount + umount). darwin-arm64-pure = 253, verified by building that target rather than subtracting 1.
- patches/0004 regenerated (88002 bytes, 27 dirs) including util-linux/{mount,umount}.c; fresh clone + apply 0001-0004 => REPRODUCES.
- README: Darwin table 255 -> 257, pure 235 -> 253 (was stale), new mount/umount row, and mount/umount dropped from the "not ported" list.
- ./test.sh: 168 passed, 0 failed.

### next up
- iostat + lsblk (IOKit / DiskArbitration, needs -framework flags in build.sh), then fdisk -l (read /dev/rdisk*), then ifconfig/route/ip (getifaddrs + NET_RT_DUMP/PF_ROUTE), then the udhcpc + mkfs/fsck assessments.

### iteration 4: ifconfig + route done
- ifconfig: getifaddrs(3) in networking/interface.c (`darwin_display_interfaces`); prints flags, mtu, ether, inet with netmask+broadcast, inet6 with prefixlen, byte counters, and a status line. `ifconfig en0` filters; `-a` shows downed too. Setting is refused (ifconfig.c's rtnetlink body compiled out under `#if !defined(__APPLE__)`).
- route: bb_displayroutes() reimplemented over sysctl(NET_RT_DUMP) (PF_ROUTE), walking rt_msghdr + RTAX_* sockaddrs with uint32 rounding. `route -n` checked against `netstat -rn`: 100.64/10 -> 255.192.0.0, 127.0.0.0/8 -> 255.0.0.0, 100.100.100.100/32 -> 255.255.255.255, default -> 0.0.0.0. add/del refuse: Darwin's struct rtentry is opaque (verified: sizeof fails even with -D_DARWIN_C_SOURCE).
- Also needed: `#define ETH_ALEN 6` in libbb/in_ether.c (macOS has no <net/ethernet.h>), and RTF_REINSTATE/DEFAULT/ADDRCONF/CACHE/NONEXTHOP defines near the top of route.c (flag tables above the setters reference them).
- Applets 257 -> 259. darwin-arm64-pure = 255.
- patches/0004 regenerated (102772 bytes, 31 dirs) incl. networking/{ifconfig,interface,route}.c + libbb/in_ether.c; fresh clone + apply 0001-0004 => REPRODUCES.
- README: count 259 (pure 255), new ifconfig/route row, deferred paragraph rewritten to list only what is genuinely still missing.
- ./test.sh 168 passed 0 failed.

### still open
- iostat, lsblk (IOKit / DiskArbitration; need -framework flags in build.sh), fdisk -l (read /dev/rdisk*), ip (map getifaddrs/PF_ROUTE onto busybox's ip object API), udhcpc (BPF).
- mkfs.*/fsck: not implementable (Linux on-disk formats; macOS uses newfs_*/fsck_*).
- read/write mount/mkfs/fdisk: not possible (opaque rtentry; mount(2) different signature; no public API to create arbitrary filesystems).

## Final Verification
- Exact monitor-rerunnable command:
    cd /Users/rcurrie/src/busybox-static && ./build.sh darwin-arm64 && dist/darwin-arm64/bin/busybox --list | wc -l && ./test.sh dist/darwin-arm64/bin/busybox 2>&1 | tail -3
- Working directory: /Users/rcurrie/src/busybox-static
- Required preserved artifacts: dist/darwin-arm64/bin/busybox, build/darwin-arm64/.config, patches/*.patch
- Result (2026-11-21): build rc=0; 259 applets; 168 passed, 0 failed. Patch series reproduces src/ from pristine upstream (diff -r --exclude=.git => no differences).

### iteration 5: fdisk -l done, plus a build reproducibility fix
- fdisk: device enumeration reads /dev/diskN (skipping diskNsM partitions) instead of /proc/partitions; geometry from DKIOCGETBLOCKSIZE/DKIOCGETBLOCKCOUNT instead of BLKGETSIZE*. MBR/GPT parsers are upstream code, unchanged.
- Writing is disabled (CONFIG_FEATURE_FDISK_WRITABLE=n) because the writer needs BLKRRPART, which Darwin lacks.
- Verified: `fdisk -l` enumerates /dev/disk0..5 and fails only with "Permission denied" (raw disks need root, same as Linux); `fdisk -l /tmp/t.img` on a hand-built MBR image prints `t.img1 * 0,1,1 1,254,63 2048 22527 20480 10.0M 83 Linux` - so the parser path works unprivileged.
- IMPORTANT FIX: applets were being enabled only in build/darwin-arm64/.config, which build-all.sh wipes. All ported applets (top, mpstat, mount, umount, ifconfig, route, fdisk + the FEATURE_TOP_* and FEATURE_FDISK_* dependents) now live in build.sh's Darwin EXTRA_CONFIG array, so a clean release build keeps them.
- Also fixed a Linux regression the full build caught: swapping <sys/mount.h> for <sys/disk.h> in fdisk.c removed the Linux source of BLKGETSIZE/BLKRRPART; now guarded so each platform gets its own header.
- Applets 259 -> 260 (arm64/amd64/universal), pure 259.
- patches/0004 regenerated (105238 bytes, 32 dirs); fresh clone + apply 0001-0004 => REPRODUCES.
- ./build-all.sh: all six targets + universal OK; ./test.sh 168 passed 0 failed.

### still open
- iostat, lsblk (IOKit / DiskArbitration; need -framework flags in build.sh - and note the pure variants must stay libSystem-only, so those applets need to be excluded there).
- ip (map getifaddrs/PF_ROUTE onto busybox's ip object API), udhcpc (BPF).
- mkfs.*/fsck: not implementable (Linux on-disk formats; macOS uses newfs_*/fsck_*).
- read/write mount/mkfs/fdisk: not possible (opaque rtentry; mount(2) signature; no filesystem-creation API).

## Final Verification
- Exact monitor-rerunnable command:
    cd /Users/rcurrie/src/busybox-static && ./build-all.sh && ./test.sh dist/darwin-arm64/bin/busybox 2>&1 | tail -3 && dist/darwin-arm64/bin/busybox --list | wc -l
- Working directory: /Users/rcurrie/src/busybox-static
- Required preserved artifacts: dist/*/bin/busybox, build/*/.config, patches/*.patch
- Result (2026-11-21, after build-all.sh from wiped build dirs): 6 targets + universal built; darwin-arm64 260 applets, darwin-amd64 260, pure 259, linux 410; test.sh 168 passed 0 failed; patch series reproduces src/ (diff -r --exclude=.git => none).

### iteration 6: iostat done (first applet with a new dylib)
- CPU: host_statistics(HOST_CPU_LOAD_INFO); uptime: KERN_BOOTTIME; disks: IOKit IOBlockStorageDriver "Statistics" (Bytes Read/Write, Operations Read/Write), BSD name from the child IOMedia.
- Four traps, all documented in docs/gotchas/linking-iokit-into-busybox-and-the-four-traps-on-the-way.md:
  1. CONFIG_EXTRA_LDLIBS prefixes -l to bare tokens, so frameworks must be `-Wl,-framework,IOKit` single tokens (not `-framework IOKit`).
  2. IOKit alone is not enough - CoreFoundation is not re-exported at link time; add -Wl,-framework,CoreFoundation.
  3. CoreFoundation must be included AFTER <locale.h> but BEFORE libbb.h, because libbb.h #defines setlocale(x,y) and CoreFoundation pulls in <locale.h>.
  4. Statistics keys are C strings needing CFSTR(); the two operations keys are ReadsKey/WritesKey ("Operations (Read)"/"Operations (Write)"), not ReadOperationsKey.
- Also: stats_cpu_t is vector[N_STATS_CPU]; a collector must fill GLOBAL_UPTIME (sum of ticks) and SMP_UPTIME (boot delta) or get_interval() returns 1 and every rate is astronomically wrong.
- Verified: `iostat` -> `disk0 433.06 tps 6558.67 Blk_read/s 11017.27 Blk_wrtn/s`, `disk5 0.20 ...`; `-d`, `-c 1 2`, `1 1` all work; CPU line matches mpstat (29.16/7.29/63.55).
- Applets 260 -> 261 (arm64/amd64/universal), pure 259 with CONFIG_IOSTAT=n.
- otool -L: darwin = libresolv + IOKit + CoreFoundation + libSystem; pure = libSystem only (verified).
- ./build-all.sh all 6 targets OK; ./test.sh 168 passed 0 failed; patches/0004 = 111972 bytes / 33 dirs and REPRODUCES from a fresh clone.

### still open
- lsblk (same IOKit machinery, would reuse the enumeration).
- ip (map getifaddrs/PF_ROUTE onto busybox's ip object API), udhcpc (BPF).
- mkfs.*/fsck: not implementable (Linux on-disk formats).
- read/write mount/mkfs/fdisk: not possible (opaque rtentry, no BLKRRPART, mount(2) signature).

## Final Verification
- Exact monitor-rerunnable command:
    cd /Users/rcurrie/src/busybox-static && ./build-all.sh && ./test.sh dist/darwin-arm64/bin/busybox 2>&1 | tail -3 && dist/darwin-arm64/bin/busybox --list | wc -l && otool -L dist/darwin-arm64-pure/bin/busybox | tail -n +2
- Working directory: /Users/rcurrie/src/busybox-static
- Required preserved artifacts: dist/*/bin/busybox, build/*/.config, patches/*.patch
- Result (2026-11-21): 6 targets + universal built; darwin-arm64 261 applets, amd64 261, pure 259; test.sh 168 passed 0 failed; pure links libSystem only; patch series reproduces src/.

### iteration 7: lsblk done
- Devices from the IOKit IOMedia tree (kIOBSDNameKey name, kIOMediaSizeKey size,

  kIOMediaWholeKey -> "disk" vs "part"); mountpoints from libbb/mntent.c's
  getmntinfo(3) layer, matching f_mntfromname against /dev/<name>. MAJ:MIN prints "-"
  because it has no macOS meaning. Output layout otherwise matches util-linux.
- Same traps as iostat, both reused knowingly: <locale.h> before libbb.h, and
  CFSTR() around the kIO*Key C-string macros (kIOBSDNameKey needs <IOKit/IOBSD.h>).
  Property reads branch on CFGetTypeID because kIOMediaWholeKey is a CFBoolean.
- Verified: `lsblk` -> `disk0 1863G disk`, `disk0s2 1858G part`,
  `disk1s1 550M part /System/Volumes/iSCPreboot`, `disk5 170K disk /Volumes/SidePulse`;
  `diskutil list` agrees on which units are physical/synthesized and on sizes.
- Applets 261 -> 262 (arm64/amd64/universal); pure stays 259 with CONFIG_LSBLK=n,
  otool -L on pure shows exactly one dependency (libSystem).
- ./build-all.sh all six targets OK; ./test.sh 168 passed 0 failed;
  patches/0004 = 116297 bytes / 34 dirs and REPRODUCES from a fresh clone.

### still open
- ip (map getifaddrs/PF_ROUTE onto busybox's ip object API), udhcpc (BPF).
- mkfs.*/fsck: not implementable (Linux on-disk formats).
- read/write mount/mkfs/fdisk: not possible (opaque rtentry, no BLKRRPART, mount(2) signature).

## Final Verification
- Exact monitor-rerunnable command:
    cd /Users/rcurrie/src/busybox-static && ./build-all.sh && ./test.sh dist/darwin-arm64/bin/busybox 2>&1 | tail -3 && dist/darwin-arm64/bin/busybox --list | wc -l && otool -L dist/darwin-arm64-pure/bin/busybox | tail -n +2
- Working directory: /Users/rcurrie/src/busybox-static
- Required preserved artifacts: dist/*/bin/busybox, build/*/.config, patches/*.patch
- Result (2026-11-21): 6 targets + universal; darwin-arm64 262 applets, amd64 262, pure 259;
  test.sh 168 passed 0 failed; pure links libSystem only; patch series reproduces src/.

### iteration 8: ip attempted, reverted (structural blocker found)
- Wrapping networking/ip.c is not enough. `CONFIG_IP=y` also makes
  networking/libiproute/Kbuild.src build eight netlink objects (ip_common.h ->
  asm/types.h, ll_types.c -> linux/if_arp.h, iplink.c -> netpacket/packet.h),
  none of which exist in the Darwin SDK.
- Disabling FEATURE_IP_* does not help: `lib-$(CONFIG_IP) +=` is unconditional on
  CONFIG_IP, and the short-form applets (ipaddr/iplink/iproute) `select` those
  FEATURE symbols.
- Renaming the kbuild keys to new undefined symbols silently drops every netlink
  object and breaks the LINUX link (undefined do_ipaddr/do_iplink). Tried, caught
  by the build, reverted.
- To finish `ip` it needs one of:
    1. a new Kconfig symbol (e.g. IP_BUILD_NETLINK, default y, depends on IP) gating
       every lib-$(CONFIG_...) line in libiproute/Kbuild.src, with build.sh setting
       it n on Darwin; or
    2. a separate ip-darwin.o applet object built behind that gate, leaving upstream
       ip.c/libiproute untouched.
  The Darwin `ip_main` body itself was written (getifaddrs for link/addr,
  NET_RT_DUMP for route) and is described in
  docs/gotchas/porting-ip-to-darwin-needs-a-kbuild-gate-not-just-an-ifdef.md.
- State restored: networking/ip.c and libiproute/Kbuild.src pristine; CONFIG_IP,
  IPADDR, IPLINK, IPROUTE back in prune/darwin-off.txt; build.sh ip lines removed.
- Verified green afterwards: ./build.sh darwin-arm64 rc=0, 262 applets,
  ./test.sh 168 passed 0 failed, patches 0001-0004 REPRODUCE src/.

### still open
- ip (needs the Kbuild gate above), udhcpc (BPF).
- mkfs.*/fsck: not implementable (Linux on-disk formats).
- read/write mount/mkfs/fdisk: not possible (opaque rtentry, no BLKRRPART, mount(2)).

## Final Verification
- Exact monitor-rerunnable command:
    cd /Users/rcurrie/src/busybox-static && ./build-all.sh && ./test.sh dist/darwin-arm64/bin/busybox 2>&1 | tail -3 && dist/darwin-arm64/bin/busybox --list | wc -l
- Working directory: /Users/rcurrie/src/busybox-static
- Required preserved artifacts: dist/*/bin/busybox, build/*/.config, patches/*.patch
- Result (2026-11-21): darwin-arm64 262 applets; test.sh 168 passed 0 failed; patch series reproduces src/.

### iteration 9: ip DONE (the Kbuild gate from iteration 8, implemented)
- New CONFIG_IP_BUILD_NETLINK symbol declared in networking/ip.c's //config block
  (default y, depends on IP || IPADDR || IPLINK || IPROUTE || IPRULE || IPTUNNEL || IPNEIGH)
  and used in networking/libiproute/Kbuild.src in place of CONFIG_IP. Darwin disables it via
  prune/darwin-off.txt, along with FEATURE_IP_{ADDRESS,LINK,ROUTE,TUNNEL,RULE,NEIGH,LINK_CAN}.
- Proof both platforms are right after ./build-all.sh:
    build/linux-amd64/networking/libiproute/*.o -> 16 objects
    build/darwin-arm64/networking/libiproute/*.o -> 1 (built-in.o, empty archive)
- Darwin ip: getifaddrs for `ip addr`/`ip link`, NET_RT_DUMP for `ip route`, plus `ip a`/`ip r`
  shorthands; setting refuses with a message. No framework needed, so ip is in the -pure builds too.
- Verified: `ip route` -> `default via 192.168.1.1 dev en0 proto static`, `100.64.0.0/10 dev utun4`;
  `ip addr` -> `1: lo0: <UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384` + inet/inet6 with prefixlen.
- Applets 262 -> 263 (arm64/amd64/universal), pure 259 -> 260.
- patches/0004 = 126838 bytes / 36 dirs, REPRODUCES from a fresh clone.
- ./build-all.sh all six targets OK; ./test.sh 168 passed 0 failed.

### still open
- udhcpc only (BPF client; macOS already runs configd/ipconfig).
- mkfs.*/fsck: not implementable. read/write mount/mkfs/fdisk: not possible.

### iteration 10: writable networking implemented
- ifconfig write path: up/down (SIOCSIFFLAGS), mtu (SIOCSIFMTU), addr[/pfx] (SIOCSIFADDR +
  SIOCSIFNETMASK), alias / -alias (SIOCAIFADDR / SIOCDIFADDR), netmask, broadcast,
  pointopoint, hw ether (SIOCSIFLLADDR).
- route add|del [-net|-host] DEST [gw GW] [dev IF] [netmask M] via a PF_ROUTE socket
  (RTM_ADD/RTM_DELETE) - struct rtentry is opaque but unnecessary for this path.
- ip link set up|down|mtu|address, ip addr add|del, ip route add|del (via / dev).
- Three bugs found by building:
  (1) ifr_addr is 16 bytes but sizeof(sockaddr_dl) is 20 -> Trace/BPT trap; fixed with
      sdl_len = offsetof(sdl_data)+6 and memset of ifr_addr only.
  (2) route_main rewrites -net/-host to #net/#host in argv, so the handler accepts both.
  (3) <net/if_dl.h> added unconditionally broke the LINUX build - now inside the Apple guard.
- Verified without root: every argument form reaches its own syscall and reports that
  specific operation (ifconfig -> "can't set mtu on lo0"; route -> "add 10.0.0.0";
  ip addr -> "can't add 10.9.9.9/24 on lo0"; ip route -> "add 10.0.0.0/8").
- Applets unchanged at 263 (pure 260); ./build-all.sh six targets + universal OK;
  ./test.sh 168 passed 0 failed; patches/0004 = 147499 bytes / 36 dirs, REPRODUCES.

### still open
- udhcpc (BPF client). media words parsed but not applied. IPv6 route add/del refused.
  ARP writes need the routing socket with an AF_LINK gateway. mkfs/fsck and read/write
  mount/fdisk remain impossible.
