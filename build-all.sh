#!/bin/bash
# Build every release target from clean build dirs, then fat-pack the Darwin pair.
#
#   ./build-all.sh              # all targets
#   ./build-all.sh linux-arm64  # only the named ones (no lipo)
#
# Every build dir is wiped first, so this is the command to use for a release:
# it cannot silently reuse objects compiled by an older toolchain or config.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

LLVM_BIN="${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin}"
ALL_TARGETS=(
	linux-amd64
	linux-arm64
	darwin-arm64
	darwin-amd64
	darwin-arm64-pure
	darwin-amd64-pure
)

if [[ $# -gt 0 ]]; then
	TARGETS=("$@")
	DO_LIPO=0
else
	TARGETS=("${ALL_TARGETS[@]}")
	DO_LIPO=1
fi

mkdir -p build dist
for t in "${TARGETS[@]}"; do
	echo "################ $t ################"
	rm -rf "build/$t"
	./build.sh "$t"
done

if [[ "$DO_LIPO" == 1 ]]; then
	echo "################ darwin-universal (lipo) ################"
	./mklipo.sh
fi

# NB: every command substitution below is guarded. `grep -c` exits 1 when the
# count is 0 (the *good* case for a static ELF) and `otool` fails outright on
# ELF input; either one would otherwise kill the script via `set -e`/pipefail.
report() {
	local t="$1" f="dist/$1/bin/busybox" size needed arch minos deps
	if [[ ! -f "$f" ]]; then
		printf '%-22s (not built)\n' "$t"
		return 0
	fi
	size="$(stat -f%z "$f")"

	if [[ "$(file -b "$f")" == ELF* ]]; then
		needed="$("$LLVM_BIN/llvm-readelf" -d "$f" 2>/dev/null | grep -c NEEDED || true)"
		arch="$("$LLVM_BIN/llvm-readelf" -h "$f" 2>/dev/null \
			| awk -F: '/Machine:/ {gsub(/^[ \t]+/, "", $2); print $2}' \
			| sed -e 's/.*X86-64/x86-64/i' -e 's/AArch64/aarch64/i' || true)"
		printf '%-22s %-14s %10s  %-9s %s\n' \
			"$t" "${arch:-elf}" "$size" "-" \
			"static (${needed:-0} NEEDED)"
		return 0
	fi

	arch="$(lipo -archs "$f" 2>/dev/null || echo '?')"
	minos="$(otool -l "$f" 2>/dev/null \
		| grep -A4 -E 'LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX' \
		| grep -oE '(minos|version) [0-9.]+' | head -1 | awk '{print $2}' || true)"
	[[ -n "$minos" ]] || minos="-"
	case "$arch" in
	*" "*)	# universal: deps are per slice, so count one slice
		deps="$(otool -L -arch arm64 "$f" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || true)"
		deps="${deps} per slice" ;;
	*)	deps="$(otool -L "$f" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || true)" ;;
	esac
	printf '%-22s %-14s %10s  %-9s %s\n' "$t" "$arch" "$size" "$minos" "$deps"
	return 0
}

echo
echo "=== dist ==="
printf '%-22s %-14s %10s  %-9s %s\n' target arch bytes minos deps
for t in "${TARGETS[@]}"; do report "$t"; done
if [[ "$DO_LIPO" == 1 ]]; then report darwin-universal; fi
