# RELEASING — shipping a new busybox build

Runbook for tracking upstream busybox and publishing artifacts to
[`rob-c/busybox-static`](https://github.com/rob-c/busybox-static).

Every command here has been executed on the tree that produced the current
`dist/`; the upgrade path was rehearsed against a *newer* upstream commit than
the one shipped (see [Rehearsed](#rehearsed)).

**Read this first:** the macOS binaries **cannot** be statically linked. Apple
ships no static libc, and arm64 macOS kills dyld-free executables. Only the
Linux targets are static. "All static targets" therefore means: Linux = fully
static ELF, Darwin = Mach-O linked against libSystem (or libSystem only, for
`-pure`). Details in `README.md` and
`docs/discoveries/static-macos-binaries-are-impossible-no-static-libc-exists-only.md`.

---

## 0. Repo setup (done)

`https://github.com/rob-c/busybox-static` exists and is **PRIVATE**, created from
this directory with `gh repo create --private --source=. --push`. 14 files, no
artifacts:

```
.gitignore  LICENSE  README.md  RELEASING.md
build.sh  build-all.sh  mklipo.sh  pack-release.sh  test.sh  stress.sh
patches/*.patch  prune/*
```

To make it public (needed if anyone else is to download the release assets —
private assets require authentication):

```sh
gh repo edit rob-c/busybox-static --visibility public
```

Recreating from scratch, if ever needed:

```sh
git init -b main && git add -A && git commit -m "..."
gh repo create rob-c/busybox-static --private --source=. --push
```

### Artifacts are excluded from git but still uploadable

These are different mechanisms and `gitignore` does **not** block uploads:

* `build/`, `dist/`, `release/`, `src/` are git-ignored — they never enter
  history, so the repo stays ~190 KB instead of ~195 MB (verified: `git
  ls-files | grep -E '^(build|dist|release|src)/'` returns nothing).
* Release assets live outside the git tree. `gh release create ... <paths>`
  uploads whatever paths you name, ignored or not.

Confirmed by attaching both a gitignored binary from `dist/` and the source
tarball from `release/` to a draft release:

```
{"assets":[{"name":"busybox","size":1485968},
           {"name":"busybox-static-1.39.0-aac079e-src.tar.gz","size":3348162}]}
```

The draft was then deleted. Note `gh release create` given a tag that does not
yet exist makes an *untagged* draft; `--cleanup-tag` then reports
`HTTP 422: Reference does not exist`. Harmless.

`src/` is deliberately **not** committed — it is a clone of upstream. The GPL
obligation to ship source is met by attaching the patched source tarball to each
release (§4), which is the `§3(a)` route and simpler than tracking 24 MB of
upstream history.

Pin the toolchain you built with, because all three are load-bearing:

```sh
zig version                              # 0.17.1
ls /opt/homebrew/opt/llvm@22/bin/llvm-ar # Apple's ar fails on empty archives
cc --version | head -1                   # Apple clang; `gcc` is a symlink to it
```

## 1. Check for a new busybox release

Our `src/` is a **shallow clone with zero tags**, so `git describe --tags` fails
with `fatal: No names found`. Use the remote instead:

```sh
# newest tagged release
git ls-remote --tags --sort=v:refname https://git.busybox.net/busybox \
  | grep -v '\^{}' | tail -3
#   fc71374...  refs/tags/1_38_0        <- tarball releases are tagged 1_38_0

# tarballs offered on the site
curl -s https://busybox.net/downloads/ \
  | grep -oE 'busybox-[0-9.]+\.tar\.bz2' | sort -u -V | tail -3

# is master ahead of what we shipped?
git -C src log -1 --format='pinned: %h %ad' --date=short
git ls-remote https://git.busybox.net/busybox refs/heads/master
```

We build **master**, not the release tarball, because the Darwin port needs
post-1.38 fixes. The in-tree `Makefile` carries `1.39.0.git` while the newest
tarball is 1.38.0 — that gap is expected, not a mistake.

Decide to proceed if the master SHA differs from `git -C src rev-parse HEAD`.

## 2. Move `src/` to the new upstream and re-apply the patches

Order matters. `git checkout FETCH_HEAD` **keeps local modifications**, so the
old patch state is carried across and the next `git apply` dies with
`error: libbb/mntent.c: already exists in working directory`. Discard first:

```sh
cd src
git reset --hard -q && git clean -fdq        # drop the applied patches
git fetch --depth 1 -q origin master
git reset --hard -q FETCH_HEAD               # move to new upstream
git log -1 --format='now at %h (%ad)' --date=short
```

Then re-apply, checking before mutating anything:

```sh
for p in ../patches/*.patch; do
  printf '%-50s ' "$(basename "$p")"
  git apply --check "$p" && git apply "$p" && echo APPLIED || echo NEEDS-FIXING
done
git status --porcelain        # expect 10 modified + libbb/mntent.c untracked
```

### If a patch no longer applies

Try the 3-way merge, which usually resolves it:

```sh
git apply --3way ../patches/0002-darwin-port.patch
```

If that fails, `git apply --reject` writes `.rej` files; fix each hunk, then
regenerate **only** that patch from the files it owns:

```sh
git diff -- coreutils/stat.c include/platform.h include/libbb.h > ../patches/0002-darwin-port.patch
```

Do not regenerate the whole series in one blob — keep the two patches separately
addressable, because `0001` is an upstream bug fix destined for submission and
`0002` is the port.

**Watch for `0001` becoming obsolete.** It deletes two `INIT_PAGESIZE(G.pagesize)`
lines from `archival/rpm.c` that reference a field the file no longer has. If
upstream fixes that, `git apply --check` will fail with *"patch does not apply"*
on `rpm.c`. Check before assuming the port broke:

```sh
grep -n 'INIT_PAGESIZE' src/archival/rpm.c   # no hits => upstream fixed it; drop 0001
```

### If a config symbol disappears or a new applet breaks the Darwin build

New upstream applets may be Linux-only and fail to compile on Darwin. Find what
owns the failing file and disable or patch it:

```sh
./prune/fail2conf.sh "$PWD/build/darwin-arm64"   # prints "source -> CONFIG symbols"
```

Add the symbol to `prune/darwin-off.txt`, or patch the source if the applet is
portable. Beware shared objects: one `.c` can serve several applets, so disabling
`FREERAMDISK` does not stop `freeramdisk.o` from being built — `FDFLUSH` does.
That is why the list also contains `FDFLUSH`, `MKE2FS`, `MKDOSFS`, `LINUX32`,
`LINUX64`, `TRACEROUTE6`.

Then also check the reverse: a `CONFIG_TC=n` workaround exists in `build.sh`
because `tc.c` still uses the CBQ qdisc API that Linux kernel headers removed.
If upstream fixes `tc.c`, drop that line and re-enable the applet.

## 3. Build every target

```sh
./build-all.sh
```

That wipes every `build/<target>/` first, so nothing is reused from an older
toolchain or `.config`, then builds six targets and fat-packs the Darwin pair.

| target | toolchain | result |
|---|---|---|
| `linux-amd64` | **zig** (`zig cc -target x86_64-linux-musl`) | static ELF, 0 `NEEDED` |
| `linux-arm64` | **zig** (`zig cc -target aarch64-linux-musl`) | static ELF, 0 `NEEDED` |
| `darwin-arm64` | Apple clang, `-mmacosx-version-min=11.0` | Mach-O, libSystem+libresolv |
| `darwin-amd64` | Apple clang, `-mmacosx-version-min=10.13` | Mach-O, libSystem+libresolv |
| `darwin-{arm64,amd64}-pure` | Apple clang, same minimums | Mach-O, **libSystem only** |
| `darwin-universal` | `lipo` of the two thin slices | universal2, one file |

Linux is where **zig** does the work: it supplies a self-contained musl
cross-compiler, so no Docker and no `musl-cross-make` is needed. Darwin cannot
use zig for this: `zig cc -target aarch64-macos -static` fails outright with
`error: libc of the specified target requires dynamic linking`, and the Darwin
targets need the macOS SDK for availability attributes and `-mmacosx-version-min`.
`zig` and Apple clang are both LLVM, so this is not a compiler change, only a
driver change.

Verify before packaging:

```sh
./test.sh   dist/darwin-arm64/bin/busybox   # 67 checks: functional
./stress.sh dist/darwin-arm64/bin/busybox   # 259 checks: adversarial, expect OK
./stress.sh dist/darwin-amd64/bin/busybox "arch -x86_64"   # Rosetta slice
docker run --rm -v "$PWD:/w:ro" debian:stable-slim \
  bash -c 'cp /w/test.sh /tmp/; chmod +x /tmp/test.sh; /tmp/test.sh /w/dist/linux-arm64/bin/busybox'
otool -L dist/darwin-arm64-pure/bin/busybox            # exactly one entry
llvm-readelf -d dist/linux-arm64/bin/busybox | grep -c NEEDED   # 0
```

## 4. Package and upload

```sh
./pack-release.sh
```

Writes `release/v<version>-<sha>/` containing the binaries, the **patched source
tarball**, the individual `.patch` files, the `.config` of every target,
`SHA256SUMS` and `NOTES.md`. It refuses to run if any `dist/` binary is missing.

It tars the *working tree* rather than using `git archive HEAD`, because the
patches are uncommitted and `libbb/mntent.c` is untracked — an archive of `HEAD`
would be unpatched source, which is exactly the GPL violation to avoid.

Review `NOTES.md`, then publish:

```sh
TAG=v1.39.0-<sha>            # printed by pack-release.sh
gh release create "$TAG" --repo rob-c/busybox-static \
  --title "busybox 1.39.0 (<sha>)" \
  --notes-file "release/$TAG/NOTES.md" \
  --target main \
  "release/$TAG"/*
```

Useful flags (verified on `gh` 2.105): `--draft` to stage privately before
publishing, `--prerelease`, `--latest=false`, `--verify-tag` to abort if the tag
does not exist, `--fail-on-no-commits` to avoid a duplicate release.

Assets are attached in order via separate API calls, so a failure mid-upload
leaves a partial release — prefer `--draft`, verify, then publish.

### Licence obligations (non-negotiable)

BusyBox is **GPLv2 only** — `src/LICENSE` states version 2 is the only version
permitted, so never label the repo or package metadata `GPL-2.0-or-later`.

Each release must ship, alongside the binaries:

* `*-src.tar.gz` — the patched source (attached by `pack-release.sh`)
* `*-configs.tar.gz` — GPLv2 §3 explicitly requires "the scripts used to control
  compilation and installation"; the `.config` per target qualifies
* the `.patch` files, so modifications are visible (`§2(a)`)
* build scripts in the repo at that tag
* `LICENSE` unchanged, and the BSD/MIT notices retained in `shell/ash.c`,
  `coreutils/{od,echo,env}.c`, `shell/math.c`, `libbb/yescrypt/*`

Keep the source asset available for as long as the binaries are downloadable.

## Troubleshooting

Symptoms seen on this project, in the order they tend to appear:

| symptom | cause | fix |
|---|---|---|
| `ar: no archive members specified` | Apple `ar` rejects empty archives; kbuild makes an empty `built-in.o` for `lib-y`-only dirs | use `llvm-ar` (already set in `build.sh`) |
| binaries only run on the build Mac's macOS | clang stamped `minos` with the SDK version | `-mmacosx-version-min` (already set); verify with `otool -l ... \| grep minos` |
| `ld: library 'crt0.o' not found` with `-static` | macOS has no static libc, ever | do not try; Linux targets are the static ones |
| `whoami: unknown uid NNN` | `USE_BB_PWD_GRP` parses `/etc/passwd`, but macOS accounts live in OpenDirectory | keep `CONFIG_USE_BB_PWD_GRP=n` |
| `fatal error: 'shadow.h' file not found` | disabling `USE_BB_PWD_GRP` makes libbb.h include `<shadow.h>` | also set `CONFIG_FEATURE_SHADOWPASSWDS=n` |
| `networking/tc.c: error: use of undeclared identifier 'TCA_CBQ_MAX'` | CBQ qdisc API removed from Linux headers | `CONFIG_TC=n` in `build.sh` |
| `archival/rpm.c: no member named 'pagesize'` | upstream regression, x86 masks it | `patches/0001` |
| `editors/diff.c: typedef redefinition ... token_t` | `<sys/mount.h>` pulls in `<bsm/audit.h>` | never include `<sys/mount.h>` from `libbb.h`; include it narrowly |
| `fatal error: 'mntent.h' file not found` | Darwin has no mntent API | `libbb/mntent.c` shim over `getmntinfo(3)` |
| `Undefined symbols: _res_9_ns_get16` | Darwin's libresolv only exports the `res_9_*` names | `CONFIG_EXTRA_LDLIBS="-lresolv"`, or use a `-pure` target |
| `error: libbb/mntent.c: already exists in working directory` | `git checkout FETCH_HEAD` kept the old patches applied | `git reset --hard && git clean -fd` first (§2) |
| `git describe` → `No names found` | `src/` is shallow with no tags | use `git ls-remote --tags` (§1) |

If a new applet fails to compile and you are unsure whether to patch or drop it:
drop it first (get a green build), then revisit. A working 235-applet binary
beats a broken 236-applet one.

## Rehearsed

The procedure in §1–§3 was executed against a pristine upstream clone at
`dce43df` (2026-11-21) — **newer** than the `aac079e` shipped in `dist/`:

```
pinned at dce43df (2026-11-21)
0001-fix-aarch64-build-rpm-pagesize.patch          APPLIES CLEANLY
0002-darwin-port.patch                             APPLIES CLEANLY
==> [linux-arm64] done          -> test.sh: 66 passed, 0 failed
==> [darwin-arm64] done         -> test.sh: 67 passed, 0 failed
```

So both patches survive at least one upstream commit, and the build works on a
tree that was never previously built.
