# busybox-static

Statically linked [busybox](https://busybox.net) built from **upstream git master
(1.39.0.git)** for Linux and macOS, plus the portability patches that make the
Darwin build possible.

| target                | format                    | link                                | applets | runs on                        |
|-----------------------|---------------------------|-------------------------------------|---------|--------------------------------|
| `linux-amd64`         | ELF x86-64                | **fully static** (musl, 0 `NEEDED`) | 410     | any Linux kernel               |
| `linux-arm64`         | ELF aarch64               | **fully static** (musl, 0 `NEEDED`) | 410     | any Linux kernel               |
| `darwin-arm64`        | Mach-O arm64              | libSystem + libresolv               | 236     | **every Apple Silicon Mac**    |
| `darwin-amd64`        | Mach-O x86-64             | libSystem + libresolv               | 236     | **every Intel Mac 10.13+**     |
| `darwin-universal`    | universal2 (both)         | libSystem + libresolv               | 236     | **every Mac, one file**        |
| `darwin-arm64-pure`   | Mach-O arm64              | **libSystem only**                  | 235     | every Apple Silicon Mac        |
| `darwin-amd64-pure`   | Mach-O x86-64             | **libSystem only**                  | 235     | every Intel Mac 10.13+         |

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

## Disabled applets (`prune/darwin-off.txt`)

The Darwin build turns off ~200 options. Everything dropped is either hard-wired
to the Linux kernel ABI or meaningless on macOS — there is no attempt to fake
`/proc`. Categories:

* **Netlink / packet sockets / Linux ioctls:** `ip`, `ifconfig`, `route`,
  `netstat`, `arp`, `brctl`, `tc`, `tunctl`, `nameif`, `ifup`/`ifdown`, `udhcpc`,
  `udhcpc6`, `udhcpd`, `ping`, `traceroute`, `ntpd` (`adjtimex`).
* **`/proc`-based:** `ps`, `top`, `pgrep`, `pkill`, `free`, `uptime`, `sysctl`,
  `fuser`, `watch`, `syslogd`, `klogd`.
* **Kernel modules:** `insmod`, `rmmod`, `lsmod`, `modprobe`, `depmod`.
* **Block devices / Linux filesystems:** `mount`, `umount`, `losetup`,
  `blkdiscard`, `lsblk`, `fdisk`, `mkfs.*`, `fsck`, `swapon`/`swapoff`.
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

* All four binaries: `./test.sh` — 66 checks (Linux) / 67 (Darwin, plus an APFS
  check) covering the shells, coreutils, grep/sed/awk, tar+gzip, diff, find,
  `df`, `stat`, `whoami`. All pass.
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
docs/             what this port learned — rules, runbook, gotchas, discoveries
build.sh          build one target
build-all.sh      build every target from clean dirs, then lipo
test.sh           functional smoke test (66 checks Linux / 67 Darwin)
stress.sh         adversarial harness: Mach-O validity, hangs, crashes, latency
                  (stress.sh --selftest proves the failure detector works)
mklipo.sh         combine the two Darwin slices into one universal2 binary
pack-release.sh   assemble release/ (binaries + source + patches + configs)
patches/          the two patches, as diffs against upstream
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
