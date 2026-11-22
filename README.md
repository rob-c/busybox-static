# busybox-static

Statically linked [busybox](https://busybox.net) built from **upstream git master
(1.39.0.git)** for Linux and macOS, plus the portability patches that make the
Darwin build possible.

**Project release: `0.3.0-dev`** (see `VERSION` and `CHANGELOG.md`) — a development
release on top of upstream busybox 1.39.0.git, shipping patches `0001`-`0008`.

| target                | format                    | link                                | applets | runs on                        |
|-----------------------|---------------------------|-------------------------------------|---------|--------------------------------|
| `linux-amd64`         | ELF x86-64                | **fully static** (musl, 0 `NEEDED`) | 416     | any Linux kernel               |
| `linux-arm64`         | ELF aarch64               | **fully static** (musl, 0 `NEEDED`) | 416     | any Linux kernel               |
| `darwin-arm64`        | Mach-O arm64              | libSystem + libresolv + IOKit       | 269     | **every Apple Silicon Mac**    |
| `darwin-amd64`        | Mach-O x86-64             | libSystem + libresolv + IOKit       | 269     | **every Intel Mac 10.13+**     |
| `darwin-universal`    | universal2 (both)         | libSystem + libresolv + IOKit       | 269     | **every Mac, one file**        |
| `darwin-arm64-pure`   | Mach-O arm64              | **libSystem only**                  | 266     | every Apple Silicon Mac        |
| `darwin-amd64-pure`   | Mach-O x86-64             | **libSystem only**                  | 266     | every Intel Mac 10.13+         |

The `-pure` builds drop `nslookup`, the only applet that needs `libresolv`, so
`libSystem.B.dylib` is the binary's sole dependency. That is the floor on macOS.

## Deployment targets: one binary per arch covers every Mac

Both Darwin binaries are built with an explicit minimum so they are not pinned to
the SDK that made them:

| arch     | `-mmacosx-version-min` | why that floor                                                        |
|----------|------------------------|-----------------------------------------------------------------------|
| `arm64`  | **11.0** (Big Sur)     | the first release *any* Apple Silicon Mac ever ran; nothing earlier exists to support |
| `x86_64` | **10.13** (High Sierra)| every Intel Mac still in service; also runs under Rosetta on Apple Silicon |

Verified in the load commands, not assumed:

```
$ otool -l dist/darwin-arm64/bin/busybox | grep minos
      minos 11.0
$ otool -l dist/darwin-amd64/bin/busybox | grep -A1 VERSION_MIN
   version 10.13
```

Without `-mmacosx-version-min`, clang stamps `minos` with **the SDK's own
version** — the first builds here said `minos 27.2`, i.e. they would refuse to
launch on anything but macOS 27.2. `.config` override: `MACOS_MIN=10.9 ./build.sh
darwin-amd64` (10.9 also links and passes the suite here, but nothing older than
this machine could be tested, so 10.13 is the shipped default).

The x86_64 slice is compiled for clang's default `penryn` baseline with **zero
AVX instructions** (checked with `otool -tv`), so it does not require a
Sandy-Bridge-era CPU; 10.13-capable Macs are all `penryn` or newer anyway.

### One file for every Mac

`./mklipo.sh` combines both slices into a universal2 binary whose two slices keep
their own minimums (arm64 11.0, x86_64 10.13) — that is legal and is what Apple's
own universal binaries do:

```
$ ./mklipo.sh
universal2: dist/darwin-universal/bin/busybox
  archs:  x86_64 arm64
  minos:  arm64 minos 11.0 / x86_64 version 10.13
  size:   1485968 bytes
$ dist/darwin-universal/bin/busybox uname -m          # arm64
$ arch -x86_64 dist/darwin-universal/bin/busybox uname -m   # x86_64
```

## Code signing

arm64 macOS **requires** a code signature, and `ld` applies an ad-hoc one
automatically (`flags=0x2(adhoc,linker-signed)`), which is why these run. x86_64
needs none, so that slice is unsigned. `lipo` drops the arm64 signature, so
`mklipo.sh` re-signs. For distributing to other people's Macs expect Gatekeeper:
an ad-hoc signed binary downloaded via a browser gets quarantined and needs
`xattr -d com.apple.quarantine`, or a Developer ID signature plus notarisation.


```sh
./build.sh linux-amd64      # or linux-arm64 / darwin-arm64 / darwin-arm64-pure ...
./build-all.sh              # all four main targets, from clean build dirs
./test.sh dist/darwin-arm64/bin/busybox
```

Output lands in `dist/<target>/` (binary at `bin/busybox`, plus the usual
symlink farm in `bin/`, `sbin/`, `usr/bin/`, `usr/sbin/`).

## Darwin is not statically linked, and cannot be

**Apple ships no static libSystem.** There is no `libc.a` for macOS, and Apple's
`ld` rejects `-static` for anything that uses libc, so a fully static Mach-O is
not a thing that exists. Measured on this machine (macOS 27.2, CLT SDK):

```
$ echo 'int main(void){return 0;}' > h.c && cc -static -o h h.c
ld: library 'crt0.o' not found
clang: error: linker command failed with exit code 1

$ find "$(xcrun --show-sdk-path)" -name 'crt0.o'          # nothing
$ find "$(xcrun --show-sdk-path)" -name 'libc.a' -o -name 'libSystem.a'   # nothing
$ ls $SDK/usr/lib | grep -c '\.tbd$'   # 583 dynamic stubs
$ ls $SDK/usr/lib | grep -c '\.a$'     # 12 archives, none of them libc
```

The SDK describes libc only as `libc.tbd`, a stub that names the dylib to load.
That is why `CONFIG_STATIC=n` for Darwin and the binary links
`/usr/lib/libSystem.B.dylib` like every other macOS program.

### Why "write your own libc" does not rescue this

On modern macOS there is not even a dynamic libc *file* to link against:

```
$ ls -la /usr/lib/libSystem.B.dylib
ls: /usr/lib/libSystem.B.dylib: No such file or directory     # it is inside
$ ls /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/
dyld_shared_cache_arm64e  dyld_shared_cache_arm64e.01  ...
```

libSystem lives in the **dyld shared cache**. And the `.tbd` stub cannot stand in
for it:

```
$ clang -static -nostdlib -o h h.c "$SDK/usr/lib/libSystem.B.tbd"
ld: warning: ignoring unexpected dylib '.../libSystem.B.tbd'
Undefined symbols for architecture arm64:
  "start", referenced from: <initial-undefines>
```

Writing a replacement libc is not a shortcut either, because Darwin's userland
ABI genuinely needs libsystem: `errno` is a libsystem call (`__error()`), thread
creation goes through `bsdthread_create`, `malloc` needs Mach VM zones, TLS is set
up by libplatform, and **signal delivery requires libsystem's `__sigtramp`** — so
even a hand-written libc would still have to reimplement that surface before
`ash`/`hush` could run. Note also that on macOS `gcc` *is* Apple clang (`gcc
--version` → "Apple clang version 21.0.0"); installing real GCC from Homebrew
does not change any of the above.

### What is achievable

`libSystem.B.dylib` as the *only* dependency — that is what `darwin-*-pure`
does, confirmed with `otool -L`. To go further you need a Linux kernel: the
`linux-arm64` binary is genuinely static (0 `NEEDED`) and runs in a `FROM
scratch` container or a Lima VM.

### And on Apple Silicon it would not run anyway

A freestanding program (no libc, raw `svc`/`syscall`) linked with
`-static -nostdlib -Wl,-e,start` is structurally a static Mach-O. Results here:

| binary | arch   | `LC_LOAD_DYLINKER` | signed | runs?                    |
|--------|--------|--------------------|--------|--------------------------|
| `s`    | arm64  | 0                  | ad-hoc | **no — `Killed: 9`**     |
| `s64`  | x86_64 | 0                  | ad-hoc | **yes, under Rosetta**   |

Same structure, same signing, different architecture — so arm64 macOS kills
dyld-free executables as policy. Even a hand-written static libc would be refused
on an M-series Mac. Only x86_64 + Rosetta tolerates a static executable, and
there is still no static libc to put in it.

What you get instead: busybox's own objects are self-contained and there are no
third-party shared dependencies. The two dylibs it references are both Apple's
own:

```
/usr/lib/libresolv.9.dylib     (nslookup: res_9_ns_* symbols)
/usr/lib/libSystem.B.dylib     (libc)
```

Linux builds *are* genuinely static — `llvm-readelf -d` reports **zero**
`NEEDED` entries, and they run in a `FROM scratch` container with no filesystem
and no libc.

If you need a Darwin build that is hermetic in the sense of "only needs
libSystem", the above is as close as the platform allows. If you need one binary
with zero external symbols, use the Linux build under a VM/container.

## Source and version

`src/` is a clone of `https://git.busybox.net/busybox` (branch `master`,
`aac079e98e19d25ed4274211e8799b64955f67be`, 2026-11-20). The version string says
`1.39.0.git`, i.e. post-1.38.0 master. The newest upstream tarball release is
1.38.0; master was used because it is the latest upstream codebase.

To rebuild after a `git pull`, delete `build/` for that target (the `.config` is
generated by `defconfig` when absent).

## Build dependencies

* `zig` — provides a self-contained musl cross-compiler (`zig cc -target
  x86_64-linux-musl`). No Docker, no `musl-cross-make`, no custom sysroot.
* LLVM binutils (`brew install llvm`) — `llvm-ar`, `llvm-ranlib`, `llvm-nm`,
  `llvm-strip`. Two reasons these are not optional:
  * Apple's `/usr/bin/ar` **fails on empty archives** (`ar: no archive members
    specified`). busybox's kbuild creates an empty `built-in.o` for any directory
    that only has `lib-y`, which is normal here.
  * Apple's `ar`/`nm`/`ld` cannot read ELF objects for the Linux targets.
* macOS SDK (Command Line Tools) for the Darwin targets.

`build.sh` expects LLVM at `/opt/homebrew/opt/llvm@22/bin`; override with
`LLVM_BIN=/path/to/bin`.

## Patches (`patches/`)

The same changes are applied in `src/`; `patches/` exists so they can be
submitted upstream.

**`0001-fix-aarch64-build-rpm-pagesize.patch`** — genuine upstream regression.
`archival/rpm.c` dropped the `pagesize` field from its globals but left two
`INIT_PAGESIZE(G.pagesize)` calls behind. On x86 `INIT_PAGESIZE()` expands to
`((void)0)`, so nothing breaks; on any arch with variable page size (aarch64) it
expands to a real assignment to a field that no longer exists and the build
fails. Any non-x86 build of master is broken by this.

**`0002-darwin-port.patch`** — the port itself (~250 lines). busybox is written
against the Linux ABI; the core fixes:

* `include/platform.h` — `bswap_64/32/16` must map to `__builtin_bswap*`
  (Darwin has no glibc `__bswap*`); `#undef` `HAVE_MEMPCPY`/`HAVE_MEMRCHR` so
  busybox's own fallbacks kick in; `st_atim/st_mtim/st_ctim` →
  `st_*timespec`; `s6_addr32`; the `ETH_P_*` ethertypes Darwin lacks;
  `BB_STATFS_NAMELEN` (`struct statfs` has no `f_namelen`); an `explicit_bzero`
  fallback (Darwin has neither `explicit_bzero` nor `memset_s`).
* `include/libbb.h` — include `<arpa/inet.h>` (`inet_aton`/`inet_pton` are
  undeclared otherwise, since Darwin's branch only included `netinet/in.h`);
  a `sigisemptyset()` fallback; declare the `mntent` API for Darwin.
* `libbb/mntent.c` (new) — `setmntent`/`getmntent`/`endmntent`/`hasmntopt` on
  top of `getmntinfo(3)`. Darwin has no `<mntent.h>` and no `/etc/mtab`; this
  keeps `df` and `find_mount_point` unchanged.
* `coreutils/stat.c` — `%T` must print `f_fstypename` (Darwin `f_type` is not a
  Linux magic number, so `stat -f` said `UNKNOWN`); include `<sys/mount.h>`.
* `libbb/poll_with_signals.c` — emulation of `ppoll()` (Darwin has none) that
  polls in 100 ms slices and re-checks `bb_got_signal` between them, so a signal
  landing in the unblock→poll window cannot hang the shell.
* `libbb/alloc_affinity.c` — `sched_getaffinity` → `hw.logicalcpu` (makes
  `nproc` correct).
* `libbb/find_mount_point.c`, `coreutils/df.c` — include `<mntent.h>` only where
  it exists.
* `networking/nslookup.c` — pull in `<arpa/nameser_compat.h>`; Darwin ships
  BIND9 headers where `HEADER`/`MAXDNAME`/`dname` moved.

One thing deliberately *not* included: `<sys/mount.h>` is not pulled into
`libbb.h`. It drags in `<bsm/audit.h>`, which defines `token_t` and collides with
`editors/diff.c`'s local typedef. Only the two files that need `struct statfs`
include it.

**`0003-gnu-long-options.patch`** — GNU long options for applets that parse only
short ones, so the same command line works in both the Linux and the Darwin
binary (see [GNU long options](#gnu-long-options-config_feature_gnu_long_opts)
below). Includes a `strverscmp()` fallback, because macOS libc has neither it nor
the GNU regex API.

## GNU long options (`CONFIG_FEATURE_GNU_LONG_OPTS`)

Busybox applets overwhelmingly parse *short* options only, so a GNU-style command
line an agent has used a thousand times — `du --max-depth=1`, `grep --line-number`,
`stat --format=%s` — was rejected even when the applet had exactly the right short
option. Of 30 such long options tested, **22 were rejected**.

Rather than add a `getopt32long()` table to ~40 applets, there is one table in
`libbb/gnu_longopts.c` mapping `(applet, --long-name) -> short letter`, and one
hook: `bb_expand_gnu_longopts()` rewrites argv *before* `getopt_long` runs. So:

* whether the option takes an argument comes from the applet's **own optstring**
  at run time, never duplicated in the table — a row cannot drift out of sync;
* `--name=value` and `--name value` both work, and `--name` for a flag that takes
  no argument is an error, as in GNU;
* `--` still ends option processing (the rewrite stops there), and names an applet
  declares itself take priority, so `grep --color=never` and `ls --full-time` are
  untouched;
* unambiguous prefixes work (`du --max-dep=1`), ambiguous ones fall through to
  busybox's normal "unrecognized option";
* no allocation: a rewritten argument is always shorter than the original, so it
  is written over the same buffer.

415 rows cover **77 applets** (coreutils, findutils, editors, archival, and every
compressor applet). Cost, measured rather than guessed: `__cstring` +2566 bytes,
`__text` +760, and **704 bytes** of Mach-O file size. `build.sh` sets it on for
every target; set `CONFIG_FEATURE_GNU_LONG_OPTS=n` to drop it.

Adding a row is one line, then `./test.sh` proves it. Two constraints, both found
the hard way:

* only map a name where that letter means what GNU means. `ls -C` colorizes here
  but selects columns in GNU, so `--format`/`--color` are deliberately absent.
  `libbb/gnu_longopts.c` has no `ls -C` row for this reason.
* applets that parse with plain `getopt()` (not `getopt32`) never reach the hook.
  `head` is the only one in the table that does this — it needs the legacy `-N`
  form and negative counts — so it calls `bb_expand_gnu_longopts()` itself.
  `awk` also uses plain `getopt` *on purpose* (it must preserve `-e`/`-f` order)
  and is left alone.

## Agent-ergonomics flags (`patches/0004`)

Features that turn multi-process agent idioms into one command. All are additive:
no existing short option changed meaning, and every one is regression-tested
(`./test.sh`, 116 checks).

| Feature | Why it matters |
|---|---|
| `grep --include=GLOB --exclude=GLOB --exclude-dir=GLOB --exclude-from=FILE` | "search this tree but skip `node_modules`" without a `find`/`xargs` pipeline. Repeatable, glob-matched on the basename, `--exclude-dir` also tests every path component so it holds regardless of traversal. |
| `find -printf 'FMT'` | one process instead of `find` + N×`stat`. Supports `%% %p %P %f %h %y %s %m %M %i %n %u %g %U %G %l %T@ %TY %Tm %Td %TH %TM %TS` and `\n \t \0 \\`. No trailing newline, as in GNU. |
| `printf %q` | shell-quote a value so a generated command can be `eval`ed safely. Works in the applet and in ash's `printf` builtin (which calls the same `printf_main`). |
| `env -C DIR` | run a command in a directory without `cd … && …` quoting bugs. |
| `xargs -d CHAR` | comma/colon-separated input; quotes are not special, `-0` and the whitespace default are untouched. |
| `realpath -m`, `--relative-to=DIR` | canonicalize paths that do not exist yet; print paths relative to a base (patch headers, `diff` labels). |
| `mktemp --suffix=SUF` | temp files that keep an extension, which tools sniff. |
| `split -d` | numeric suffixes (`x00`, `x01`) instead of alphabetic. |
| `column -t [-s SEP] [-o SEP]` | new applet: align fields into columns. Agents print tables constantly; without it every one is hand-padded `awk`/`printf`. |
| **ash brace expansion** | `{a,b}`, `{1..5}`, `{5..1}`, `{1..9..3}`, `{a..e}`, nesting, and zero padding (`{01..03}`), all before other expansions. Quoted braces stay literal: `"a{b,c}d"` and `sed "s/x/{p,q}/"` are untouched, because the tokenizer marks quoted `{`, `}`, `,` with `CTLESC` and the expander skips marked bytes. |
| **ash `${v^^}` `${v,,}` `${v^}` `${v,}`** | bash case conversion. `VSTYPE` was widened to `0x1f` (with `VSNUL` moved to `0x20`) so each of the four forms has its own subtype; the lexer consumes both operator characters, and `evalvar()` consumes `CTLENDVAR` because the caller reads the original type byte and expects an operator subtype to have done so — omitting that is what made an earlier attempt eat the character after the expansion. |
| **Darwin process layer** | `ps`, `pgrep`, `pkill`, `pstree`, `pidof` and `killall` now work on macOS. `procps_status_t` is filled from `sysctl(KERN_PROC_ALL)` (pid/ppid/pgid/sid/uid/gid/`p_comm`/`p_stat`) plus `KERN_PROCARGS2` for argv. Two things make it correct: the iteration cursor lives in a file-static snapshot (callers `memset` the struct per process), and the argv walk is bounded by `argc`, by a byte cap, **and** stops at the first `KEY=value` string with the pointer rewound — without that rewind `ps` printed `PATH=` from the environment. Name matching is comm, then `basename(argv[0])`, then `basename(argv[1])` when `argv[0]` is a shell (macOS reports the interpreter in `p_comm` for scripts); it deliberately does *not* match other arguments, so `killall foo` cannot kill `grep foo`. |
| **applet gap closed to 263** | `watch`, `reset`, `fallocate`, `chpst`, `setuidgid`, `envuidgid`, `softlimit` enabled with no code changes, and `free`, `uptime` (+ `ps`) via `include/sysinfo_compat.h`: a minimal `struct sysinfo` filled from `KERN_BOOTTIME`, `hw.memsize`, `host_statistics64` and `getloadavg`, plus `posix_fallocate` on `fcntl(F_PREALLOCATE)`. Busybox `uptime` now matches `/usr/bin/uptime` including load averages (they are 1/2048 units, not 1/65536). Also ported: **`readahead`** (via `fcntl(F_RDADVISE)`), **`fuser`** (libproc enumeration, matching `dev`/`ino` like the /proc version; PORT/PROTO arguments report that they need `/proc/net`), **`lsof`** (libproc `PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`) and **`ping`/`ping6`** (BSD ICMP type names, `struct ip` instead of `struct iphdr`, `ip_hl`/`ip_ttl`, `SOL_IPV6`). `ping` needs root, exactly as the Linux build does — these binaries are not setuid. |
| **`vmstat`, `mpstat`, `top`** | `vmstat` fills its 18 columns from `host_statistics` plus `sysctl vm.swapusage`. `mpstat` reads per-CPU ticks from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` and uptime from `KERN_BOOTTIME`; `-P ALL` works, and the interrupt reports (`-I`) print 0.00 because macOS has no interrupts counter. `top -b -n1` prints the Mem/CPU/Load-average header and per-process `%RSS`/`%CPU` from `proc_pidinfo(PROC_PIDTASKINFO)`. The hidden blocker in all three was `get_cpu_count()` in **libbb**, which opened `/proc/stat` before any applet code ran. Known limit: macOS reports `p_stat == SRUN` for *every* process, even a sleeping one, so the `STAT` column shows `R` where Apple's `ps` shows `S`. |
| **`mount`, `umount`** | Read-only, built on the `getmntinfo(3)` layer that `libbb/mntent.c` already provides for `df`: `mount` prints all 13 mounted filesystems and honours `-t fstype`. Actually mounting is refused with `ENOSYS` ("Function not implemented") because Darwin's `mount(2)` takes different arguments and `<sys/mount.h>` has no `MS_*` flag set; the `-o` parser and the `type (opts)` printer get private flag values. Use `diskutil(8)` or the system `mount(8)` to mount. |
| **`ifconfig`, `route`** | Read-WRITE, from `getifaddrs(3)` and `sysctl(NET_RT_DUMP)` over `PF_ROUTE`. `ifconfig` prints flags, `mtu`, `ether`, `inet`/`inet6` with netmask and prefixlen, and byte counters; `ifconfig en0` filters to one interface. `route -n` prints the IPv4 table (checked against `netstat -rn`: `100.64/10` -> `255.192.0.0`, `127.0.0.0/8` -> `255.0.0.0`). Setting works through the BSD ioctls (`SIOCSIFFLAGS`, `SIOCSIFMTU`, `SIOCSIFADDR`, `SIOCAIFADDR`/`SIOCDIFADDR` aliases, `SIOCSIFLLADDR`, `SIOCSIFNETMASK`, `SIOCSIFBRDADDR`) and `route add/del` through a `PF_ROUTE` socket (`RTM_ADD`/`RTM_DELETE`) - `struct rtentry` is opaque but is not needed for that path. Requires root, as on Linux. |
| **`fdisk -l`** | Device enumeration reads `/dev/diskN` (skipping `diskN sM` partitions) instead of `/proc/partitions`, and geometry comes from `DKIOCGETBLOCKSIZE`/`DKIOCGETBLOCKCOUNT` instead of `BLKGETSIZE*`. The MBR and GPT parsers are upstream code, unchanged. Reading a whole disk needs root, exactly as on Linux; `fdisk -l image.img` works unprivileged and was checked against a hand-built MBR (`/tmp/t.img1 * 0,1,1 1,254,63 2048 22527 20480 10.0M 83 Linux`). Writing a partition table is not supported. |
| **`iostat`** | CPU from `host_statistics(HOST_CPU_LOAD_INFO)`, uptime from `KERN_BOOTTIME`, and per-disk throughput from IOKit `IOBlockStorageDriver` "Statistics" (`Bytes (Read)`/`Bytes (Write)`/`Operations (Read)`/`Operations (Write)`), with the BSD name taken from the driver's child `IOMedia`. Checked against `iostat 1 1` on Linux for column layout, and `disk0`/`disk5` appear with plausible rates. This is the only applet needing extra dylibs: `IOKit.framework` and `CoreFoundation.framework` (both public, present since 10.x), added to the Darwin link line as `-Wl,-framework,IOKit -Wl,-framework,CoreFoundation`. The `-pure` variants build with `CONFIG_IOSTAT=n` so they stay libSystem-only. |
| **`lsblk`** | Devices from the IOKit `IOMedia` tree (`kIOBSDNameKey`, `kIOMediaSizeKey`, `kIOMediaWholeKey`), mountpoints from the same `getmntinfo(3)` layer `mount`/`df` use. Prints `disk0 1863G disk`, `disk0s2 1858G part`, `disk1s1 550M part /System/Volumes/iSCPreboot` and so on; `MAJ:MIN` has no macOS meaning so that column shows `-`. Uses the IOKit dylibs already linked for `iostat`, and is likewise disabled in the `-pure` variants. |
| **`ip`** | `ip addr` / `ip link` / `ip route`, read and write (and the `ip a` / `ip r` shorthands), built on `getifaddrs(3)` and `sysctl(NET_RT_DUMP)` like `ifconfig` and `route`. `ip route` prints `default via 192.168.1.1 dev en0 proto static`, `100.64.0.0/10 dev utun4`; `ip addr` lists `inet`/`inet6` with prefixlen. Setting works (`ip link set`, `ip addr add|del`, `ip route add|del`). Needs no extra dylib, so it is present in the `-pure` builds too. Reaching it required a build-system change: `CONFIG_IP` pulls in eight rtnetlink objects from `networking/libiproute`, so a new `CONFIG_IP_BUILD_NETLINK` symbol (default y, disabled in `prune/darwin-off.txt`) now gates that kbuild block - Linux still builds all 16 objects, Darwin builds none. |
| `$SECONDS` in ash | seconds since the shell started, implemented as a dynamic variable beside `$EPOCHSECONDS` (`shell/ash.c`, `change_shseconds()`), so it updates on every read. |
| `unzip` Zip64 sizes | `unzip -l` reported `4294967295` for any entry whose *local* header is Zip64 (python writes Zip64 only there). Sizes are now taken from the central directory, and its `0x0001` extra field is parsed when the CDF itself carries `0xffffffff`. |

Two implementation notes worth knowing before extending these:

* **`-printf` lives in `find`'s `params[]` string table, whose order must match the `PARM_*` enum.** Inserting the name anywhere else shifts every later option (`-name` stops working) — the same failure mode bit twice here.
* **`getopt32` assigns flag bits by position in the optstring**, not by the enum. A long-only option whose `\xfe`-style value has no optstring slot cannot be detected with `opt & OPT_X`; test the captured `char *` instead (that is what `xargs -d` does).

**Deferred** (verified absent, not attempted here): `date -d` relative expressions, `grep -z`/`sed -z`, and `timeout` exiting 124 instead of 128+signal (GNU's default; busybox already behaves like `--preserve-status`). Still off on Darwin: `udhcpc`, `mkfs.*`, `fsck`, `syslogd`/`klogd` and `su`/`passwd`. Each needs a macOS backend rather than a port — `getifaddrs`+`PF_ROUTE` mapped onto `ip's object API`, BPF for DHCP, and OpenDirectory for the account tools. `mkfs.*` and `fsck` write and check Linux on-disk formats, so they have no Darwin equivalent at all (macOS uses `newfs_*`/`fsck_*`). `ps -o exe` shows the executable path because the Darwin `procps_scan` fills `exe` from argv[0].

The process layer replaced 8 applets' worth of `/proc` assumptions with two sysctls; the two traps (a cursor callers can `memset` away, and an argv walk that must rewind at the environment boundary) are written up in `docs/gotchas/darwin-procps-*.md`, and the name-matching rule in `docs/decisions/darwin-process-matching-argv-not-comm.md`.



### What the two ash features needed

Both took several failed attempts, all reverted before landing, and the two traps are worth knowing.

**Brace expansion needs a quoting signal.** ash strips quotes before `expandarg()` runs, so the first version also expanded `"a{b,c}d"` and corrupted `sed`, `awk` and JSON through `busybox sh`. The fix is upstream of that: `readtoken1`'s `case CWORD` emits `CTLESC` before `{`, `}` and `,` inside a quoted run (the same marker ash already uses for quoted glob characters), and the expander skips `CTLESC`-prefixed bytes.

**Case modifiers must consume `CTLENDVAR`.** `parsesub` gives `${v^}` and `${v^^}` no subtype and drops the first operator character, so the working version widened `VSTYPE` to `0x1f`, moved `VSNUL` to `0x20`, and gave each of the four forms its own subtype. The last bug was one eaten character after the expansion: the caller re-reads the type byte and, for an operator subtype, assumes `evalvar()` consumed `CTLENDVAR` - so it must, explicitly. Without that, `printf "A${v^^}B"` prints `AAB`.

Regression tests for both are in `test.sh` (the `ash:` and `brace:` checks), including quoted braces and the no-eaten-character case.

## Agent applets (`patches/0006`-`0008`)

Six new applets and one libbb module implementing `AGENT-FEATURES.md`, split
one patch per tier so each can be dropped independently:

| patch | contents |
|---|---|
| `0006-agent-ops-core.patch` | `libbb/json_read.c` + `include/json_read.h`, `busybox --caps [--format json]`, **`peek`** (bounded/versioned reads, `--request` batch), **`waitfor`** (file/tcp/unix/http readiness) |
| `0007-agent-ops-edit.patch` | **`replace`** — literal, all-or-nothing, `--expect`, `--sha256`, `--dry-run`, symlink policy, atomic temp+rename |
| `0008-agent-ops-run.patch` | **`run`** (captured execution, process-group kill, artifacts) + **`log`** (bounded retrieval) + **`doctor`** |

All six are cross-platform: they use only POSIX and existing `libbb` helpers, and
`./test.sh` covers them on every target. Exit codes are 0/1/2/3 (never 124 or
128+N), JSON output is `{"schema":1,...}`, and every output has a byte budget
with an explicit truncation cursor. See `AGENT-FEATURES.md` for the contract and
the rejected ideas.

## Disabled applets (`prune/darwin-off.txt`)

The Darwin build turns off ~200 options. Everything dropped is either hard-wired
to the Linux kernel ABI or meaningless on macOS — there is no attempt to fake
`/proc`. Categories:

* **Netlink / packet sockets / Linux ioctls:** `ip`, `ifconfig`, `route`,
  `netstat`, `arp`, `brctl`, `tc`, `tunctl`, `nameif`, `ifup`/`ifdown`, `udhcpc`,
  `udhcpc6`, `udhcpd`, `ping`, `traceroute`, `ntpd` (`adjtimex`).
* **`/proc`-based:** `sysctl`, `watch`, `syslogd`, `klogd`.
* **Kernel modules:** `insmod`, `rmmod`, `lsmod`, `modprobe`, `depmod`.
* **Block devices / Linux filesystems:** `losetup`, `blkdiscard`, `lsblk`,
  `mkfs.*`, `fsck`, `swapon`/`swapoff` (`mount`/`umount`/`ifconfig`/`route`/`fdisk`
  are present read-only: they list, but cannot change anything).
* **mtd / i2c / framebuffer / watchdog / hw:** `nandwrite`, `ubi*`, `flashcp`,
  `i2c*`, `fbsplash`, `watchdog`, `hdparm`, `setserial`.
* **init/console:** `init`, `mdev`, `openvt`, `showkey`, `loadfont`, `chvt`.
* **Account tools** (`adduser`, `passwd`, `su`, `login`, …): macOS accounts come
  from OpenDirectory, not `/etc/passwd`.
* **Features:** `USE_BB_PWD_GRP` (busybox's own `/etc/passwd` parser cannot see
  OpenDirectory users — this is what made `whoami` say *unknown uid 504*),
  `FEATURE_SHADOWPASSWDS` (no `/etc/shadow`), `FEATURE_USE_SENDFILE` (macOS
  `sendfile` only targets sockets), `SHA*_HWACCEL` (the `.S` files are ELF
  syntax and cannot be assembled into Mach-O).

`nproc`, `uname`, `id`, `whoami`, `df`, `stat`, `ls`, `grep`, `sed`, `awk`, `vi`,
`ash`, `hush`, `tar`, `gzip`/`bzip2`, `find`, `xargs`, `diff`, `sort`, `dd` and
the rest of coreutils/archival/findutils/editors work.

## Verification performed

* All four binaries: `./test.sh` — 94 checks on Darwin (including a
  `CONFIG_FEATURE_GNU_LONG_OPTS` block that skips itself if the feature is off),
  covering the shells, coreutils, grep/sed/awk, tar+gzip, diff, find, `df`, `stat`,
  `whoami`, and the GNU long-option rewrite. All pass.
* GNU long options, cross-platform: every one of the 415 table rows was run as
  `--long` *and* as its short form and required to produce identical exit status,
  stdout and stderr (415/415). The `linux-arm64` binary was then run in a
  container (`docker run --platform linux/arm64`) and accepts the same rows;
  `sort --version-sort` gives **identical** output on both, including the
  leading-zero cases that separate `strverscmp()` implementations.
* Adversarial: `./stress.sh` — 258–259 checks per build across six Darwin
  artifact/slice combinations (thin arm64, thin x86_64 via Rosetta, the `-pure`
  pair, and both universal2 slices): **0 failures, 0 hangs, 0 crashes**. It
  covers Mach-O/signature validity, applet dispatch, shell grammar accepted vs
  rejected, malformed gzip/bzip2/tar/zip, NUL and invalid UTF-8 corpora, 200 KB
  single lines, symlink loops, FIFOs, `/dev/null` stdin, SIGPIPE, and interrupt
  latency. Signal cases assert *promptness* (ms), not merely nonzero exit — see
  `docs/gotchas/` for why a watchdog SIGKILL makes a naive assertion worthless.
* Linux static-ness: both binaries run in `FROM scratch` containers (no libc, no
  filesystem) — `uname`, `awk`, `sha256sum`, `tar czf` all work, and
  `llvm-readelf -d` shows 0 `NEEDED` entries.
* Darwin dylib links: only `/usr/lib/libSystem.B.dylib` and
  `/usr/lib/libresolv.9.dylib` (`otool -L`), both OS-provided.
* Darwin static linking is impossible, measured not assumed: `cc -static` and
  `gcc -static` on a one-line C file fail with `ld: library 'crt0.o' not found`;
  the SDK contains no `crt0.o`, no `libc.a` and no `libSystem.a`, only 583 `.tbd`
  dylib stubs; `/usr/lib/libSystem.B.dylib` is not a file on disk at all (dyld
  shared cache).
* `darwin-arm64-pure`: `otool -L` lists **one** entry, `/usr/lib/libSystem.B.dylib`;
  235 applets; `./test.sh` => 67 passed, 0 failed; 235-applet sweep => 0 crashed,
  0 hung.
* Darwin: `whoami` resolves the real user, `stat -f -c %T` reports `apfs`,
  `df -h` reports real APFS volumes.
* `patches/0001` and `patches/0002` apply cleanly to a pristine upstream clone
  (`git apply --check`).

## Layout

```
README.md         what this is, the platform limits, the evidence
RELEASING.md      runbook: bump upstream, re-apply patches, build, publish
AGENT-FEATURES.md proposal: which agent-facing applets to add to this tree and how
docs/             what this port learned — rules, runbook, gotchas, discoveries
build.sh          build one target
build-all.sh      build every target from clean dirs, then lipo
test.sh           functional smoke test (168 checks incl. GNU long options;
                  runs on Darwin and on Linux hosts, containers and VMs)
stress.sh         adversarial harness: Mach-O validity, hangs, crashes, latency
                  (stress.sh --selftest proves the failure detector works)
mklipo.sh         combine the two Darwin slices into one universal2 binary
pack-release.sh   assemble release/ (binaries + source + patches + configs)
patches/          the patches, as diffs against upstream
prune/
  darwin-off.txt  CONFIG symbols disabled for Darwin
  apply-off.sh    apply that list to a .config
  fail2conf.sh    helper: map failing sources -> CONFIG symbols
LICENSE           busybox's GPLv2 text (v2 only, no "or later")
src/              upstream clone, patched in place (git-ignored)
build/<target>/   out-of-tree build dirs (.config lives here)
dist/<target>/    install tree + symlink farm
release/<tag>/    packaged artifacts, ready for gh release create
```

Shipping a new build? Start at [RELEASING.md](RELEASING.md).

Everything this port learned the hard way — why macOS can never be static, why
Apple's `ar` breaks kbuild, why a watchdog `SIGKILL` makes interrupt tests pass
vacuously — is written up in [docs/](docs/), indexed in
[docs/README.md](docs/README.md).

## Testing

Runnable against any built binary:

```
./test.sh                  dist/darwin-arm64/bin/busybox   # 198 smoke checks
./tests/agent-ops.sh       dist/darwin-arm64/bin/busybox   # 1299 agent-applet checks
./tests/timeout-resilience.sh dist/darwin-arm64/bin/busybox # 50 deadline checks
./tests/timeout-resilience-matrix.sh dist/darwin-arm64/bin/busybox # 200 more
./tests/wrapper-signals.sh dist/darwin-arm64/bin/busybox # 21 kill-the-wrapper checks
./stress.sh                dist/darwin-arm64/bin/busybox   # per-applet stability
./adversarial.sh           dist/darwin-arm64/bin/busybox   # ~1270 hostile-input checks
```

`tests/timeout-resilience-matrix.sh` multiplies the same idea: 10 hostile guests
(trap-and-loop, trap-and-exit-0, trap-and-exit-3, ignore TERM/INT/HUP/QUIT,
trap that blocks inside the handler, child that ignores, subshell that ignores,
looping sleeps, CPU spin) × 4 invocation paths (`run --timeout`,
`run --kill-after`, `sh --timeout`, `run --brief`) × 5 assertions (exit 3, never
124, never 128+N, no survivor, inside the grace window) = 200 checks, run on
darwin-arm64 and in `almalinux:9`.

`tests/timeout-resilience.sh` is the one that matters for deadlines: every guest
either traps `TERM` and keeps running, traps it and exits 0, ignores
`TERM`/`INT`/`HUP`, or leaves a grandchild doing the same. All 50 checks assert
that `run --timeout` and `sh --timeout` still exit **3** on time, that the guest
is killed rather than merely signalled, and that no process survives — the checks
have teeth because the same `ps` scan is verified to see a deliberately leaked
process.

`adversarial.sh` attacks every applet with bad options, 4 KiB of random stdin and
oversized arguments, then works through filename hostility (embedded newlines,
NFD/NFC unicode, APFS case-insensitivity), format-string and escape abuse, 1 MiB
lines, 200k-line sorts, symlink loops, a tar member named `../escape.txt`,
empty/broken environments, Darwin-specific behaviour (no `/proc`; `mount`,
`lsblk`, `ifconfig`, `route`, `ip` must answer; mutating networking must `EPERM`
as non-root), SIGPIPE, and differentials against the system `sort`/`base64`/
`md5`/`wc`/`cut`.

Current results: `darwin-arm64` 1269 pass / 0 fail, `darwin-arm64-pure` 1252
pass / 0 fail, `darwin-amd64` via Rosetta 1268 pass / 0 fail, no known failures.
(`hush` used to segfault on an ETX byte inside a command substitution; that is
fixed in patch 0004.)

It excludes applets that can signal or reconfigure the machine — `kill`,
`pkill`, `killall`, `shutdown`, `reboot`, `rtcwake`, `devmem`, `sysctl`,
`mount` and friends are never given synthetic arguments.
