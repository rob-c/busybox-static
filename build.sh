#!/bin/bash
# Build static busybox from the upstream git tree for Linux (musl) and Darwin.
#
#   ./build.sh linux-amd64     ELF x86-64, statically linked against musl
#   ./build.sh linux-arm64     ELF aarch64, statically linked against musl
#   ./build.sh darwin-arm64    Mach-O arm64, linked against libSystem
#
# Linux builds use zig as a self-contained musl cross toolchain (no Docker,
# no brew musl-cross). Darwin builds use the host SDK.
#
# Result: dist/<target>/bin/busybox + the usual applet symlink farm.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
TARGET="${1:?usage: build.sh TARGET (linux-amd64, linux-arm64, darwin-arm64, darwin-amd64, darwin-arm64-pure, darwin-amd64-pure)}"
BUILD="$ROOT/build/$TARGET"
DIST="$ROOT/dist"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# LLVM binutils. Apple's /usr/bin/ar rejects empty archives (which busybox's
# kbuild creates for directories that only have lib-y), and Apple's ld/nm
# cannot read ELF, so always use the llvm ones.
LLVM_BIN="${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin}"

mkdir -p "$BUILD" "$DIST"

case "$TARGET" in
linux-amd64) ZIGTRIPLE=x86_64-linux-musl ; LD_EMUL=elf_x86_64 ;;
linux-arm64) ZIGTRIPLE=aarch64-linux-musl; LD_EMUL=aarch64linux ;;
# Minimum macOS per arch, so one binary per arch covers every Mac of that arch:
#  * arm64:  11.0 Big Sur - the first release any Apple Silicon Mac ever ran.
#  * x86_64: 10.13 High Sierra - every Intel Mac still in use, plus Rosetta.
# Without this, clang stamps minos with the SDK's own version (here 27.2) and the
# binary refuses to launch on anything older. Override with MACOS_MIN=...
darwin-arm64) ZIGTRIPLE=; LD_EMUL=; DARCH=arm64;  MINV=${MACOS_MIN:-11.0} ;;
darwin-amd64) ZIGTRIPLE=; LD_EMUL=; DARCH=x86_64; MINV=${MACOS_MIN:-10.13} ;;
# "-pure": drop the only applet (nslookup) that needs a second dylib, so the
# result links libSystem and nothing else. As static as a Mach-O can get.
darwin-arm64-pure) ZIGTRIPLE=; LD_EMUL=; DARCH=arm64;  MINV=${MACOS_MIN:-11.0};  PURE=1 ;;
darwin-amd64-pure) ZIGTRIPLE=; LD_EMUL=; DARCH=x86_64; MINV=${MACOS_MIN:-10.13}; PURE=1 ;;
*) echo "unknown target: $TARGET" >&2; exit 1 ;;
esac

if [[ -n "$ZIGTRIPLE" ]]; then
	# -------------------------------------------------------------- Linux/musl
	TOOLCHAIN=(
		CC="zig cc -target $ZIGTRIPLE"
		AR="$LLVM_BIN/llvm-ar"
		LD="zig ld.lld -m $LD_EMUL"
		NM="$LLVM_BIN/llvm-nm"
		STRIP="$LLVM_BIN/llvm-strip"
		OBJCOPY="zig objcopy"
		RANLIB="$LLVM_BIN/llvm-ranlib"
	)
	EXTRA_CONFIG=(
		"CONFIG_STATIC=y"        # -static: real static ELF against musl
		"CONFIG_STATIC_LIBGCC=n" # no libgcc.a with clang/zig
		# GNU long options for applets that only parse short ones, so the
		# same command line works in both the Linux and the Darwin binary.
		"CONFIG_FEATURE_GNU_LONG_OPTS=y"
		# agent-facing table formatter (new applet, patch 0004)
		"CONFIG_COLUMN=y"
		# agent-facing applets (patch 0006): bounded reads, readiness
		"CONFIG_PEEK=y"
		"CONFIG_REPLACE=y"
		"CONFIG_RUN=y"
		"CONFIG_LOG=y"
		"CONFIG_DOCTOR=y"
		"CONFIG_WHY=y"
		"CONFIG_WAITFOR=y"
		"CONFIG_JSON=y"
		"CONFIG_PATCHCHECK=y"
		"CONFIG_BENCH=y"
		# tc.c still uses the CBQ qdisc API, removed from Linux kernel headers
		# (sched_cbq was deleted in Linux 6.x), so it cannot compile here.
		"CONFIG_TC=n"
	)
else
	# ------------------------------------------------------------------ Darwin
	TOOLCHAIN=(
		CC="cc -arch $DARCH -mmacosx-version-min=$MINV"
		AR="$LLVM_BIN/llvm-ar"
		NM="$LLVM_BIN/llvm-nm"
		STRIP="$LLVM_BIN/llvm-strip"
		OBJCOPY="zig objcopy"
		RANLIB="$LLVM_BIN/llvm-ranlib"
	)
	# Apple ships no static libSystem, so -static cannot work. The binary is a
	# plain Mach-O: our objects are self-contained, but libc comes from the OS.
	EXTRA_CONFIG=(
		"CONFIG_STATIC=n"
		"CONFIG_STATIC_LIBGCC=n"
		"CONFIG_PIE=n"
		# Same long-option support as the Linux builds: one command line,
		# identical behaviour on both platforms.
		"CONFIG_FEATURE_GNU_LONG_OPTS=y"
		# agent-facing table formatter (new applet, patch 0004)
		"CONFIG_COLUMN=y"
		# agent-facing applets (patch 0006): bounded reads, readiness
		"CONFIG_PEEK=y"
		"CONFIG_REPLACE=y"
		"CONFIG_RUN=y"
		"CONFIG_LOG=y"
		"CONFIG_DOCTOR=y"
		"CONFIG_WHY=y"
		"CONFIG_WAITFOR=y"
		"CONFIG_JSON=y"
		"CONFIG_PATCHCHECK=y"
		"CONFIG_BENCH=y"
		# Applets ported to macOS in patch 0004.  They must be listed here,
		# not just edited into build/<target>/.config: build-all.sh wipes the
		# build dirs, so anything set only in a .config is lost on a clean
		# release build.  Each of these is pruned out of darwin-off.txt.
		"CONFIG_TOP=y"
		"CONFIG_MPSTAT=y"
		"CONFIG_MOUNT=y"
		"CONFIG_UMOUNT=y"
		"CONFIG_IFCONFIG=y"
		"CONFIG_ROUTE=y"
		"CONFIG_FDISK=y"
		"CONFIG_IOSTAT=y"
		"CONFIG_LSBLK=y"
		"CONFIG_IP=y"
		# Only -l (listing) is supported on Darwin: writing needs BLKRRPART and
		# the DOS/GPT writers, whose ioctls do not exist here.
		"CONFIG_FEATURE_FDISK_WRITABLE=n"
		"CONFIG_FEATURE_FDISK_ADVANCED=n"
		# top's per-CPU and percentage columns are separate symbols that
		# default to n once TOP was ever disabled; without them top prints
		# no CPU line and no %CPU column.
		"CONFIG_FEATURE_TOP_INTERACTIVE=y"
		"CONFIG_FEATURE_TOP_CPU_USAGE_PERCENTAGE=y"
		"CONFIG_FEATURE_TOP_CPU_GLOBAL_PERCENTS=y"
		"CONFIG_FEATURE_TOP_DECIMALS=y"
	)
	if [[ "${PURE:-0}" == 1 ]]; then
		# nslookup is the only applet needing libresolv; without it the binary
		# depends on libSystem.B.dylib alone.
		EXTRA_CONFIG+=("CONFIG_NSLOOKUP=n")
		# iostat needs IOKit, which would add a second dylib
		EXTRA_CONFIG+=("CONFIG_IOSTAT=n"
		"CONFIG_LSBLK=n")
	else
		# nslookup uses ns_get16/ns_parserr etc, which Darwin's libresolv
		# only exports as res_9_ns_* (so they must be linked explicitly)
		# -framework IOKit: public on every supported macOS, used by iostat
		EXTRA_CONFIG+=("CONFIG_EXTRA_LDLIBS=\"-lresolv -Wl,-framework,IOKit -Wl,-framework,CoreFoundation\"")
	fi
fi

echo "==> [$TARGET] configuring"
if [[ ! -f "$BUILD/.config" ]]; then
	make -C "$SRC" O="$BUILD" defconfig </dev/null >/dev/null 2>&1
fi

# set a config symbol, handling kconfig's "disabled == comment" spelling
set_cfg() {
	local k="$1" v="$2"
	if grep -qE "^(# )?${k}(=| is not set)" "$BUILD/.config"; then
		if [[ "$v" == n ]]; then
			sed -i '' -e "s|^${k}=.*|# ${k} is not set|" -e "s|^# ${k} is not set|# ${k} is not set|" "$BUILD/.config"
		else
			sed -i '' -e "s|^# ${k} is not set|${k}=${v}|" -e "s|^${k}=.*|${k}=${v}|" "$BUILD/.config"
		fi
	else
		# symbol absent from this .config: kconfig will prompt for it unless we
		# write a value (quoted for string symbols) before oldconfig runs
		if [[ "$v" == n ]]; then
			echo "# ${k} is not set" >> "$BUILD/.config"
		else
			echo "${k}=${v}" >> "$BUILD/.config"
		fi
	fi
}

for kv in "${EXTRA_CONFIG[@]}"; do
	set_cfg "${kv%%=*}" "${kv#*=}"
done

if [[ "$TARGET" == darwin-* ]]; then
	# Linux-kernel-only applets cannot build against the Darwin SDK
	"$ROOT/prune/apply-off.sh" "$BUILD" "$ROOT/prune/darwin-off.txt" >/dev/null
else
	make -C "$SRC" O="$BUILD" oldconfig </dev/null >/dev/null 2>&1 || true
fi

echo "==> [$TARGET] building (-j$JOBS)"
make -C "$SRC" O="$BUILD" -j"$JOBS" "${TOOLCHAIN[@]}" 2>&1 \
	| grep -vE '^zig: warning|^clang: warning|warning:|note:|^ *[0-9]+ \||^ *\||^ *\^|^ +[0-9]+ \| ' || true

BB="$BUILD/busybox"
[[ -x "$BB" ]] || { echo "!! build produced no binary; see errors above" >&2; exit 1; }

echo "==> [$TARGET] installing to dist/$TARGET"
rm -rf "${DIST:?}/$TARGET"
make -C "$SRC" O="$BUILD" "${TOOLCHAIN[@]}" CONFIG_PREFIX="$DIST/$TARGET" install >/dev/null

echo "==> [$TARGET] done: $DIST/$TARGET/bin/busybox"
