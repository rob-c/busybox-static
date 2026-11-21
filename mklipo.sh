#!/bin/bash
# Combine the arm64 and x86_64 Darwin builds into ONE universal2 binary, so a
# single file runs on every Mac (native on Apple Silicon, Rosetta on Intel, and
# natively on Intel).
#
#   ./mklipo.sh                       # dist/darwin-{arm64,amd64} -> darwin-universal
#   ./mklipo.sh dist/a dist/b dist/out
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A="${1:-$ROOT/dist/darwin-arm64}"
B="${2:-$ROOT/dist/darwin-amd64}"
OUT="${3:-$ROOT/dist/darwin-universal}"

for d in "$A" "$B"; do
	[[ -x "$d/bin/busybox" ]] || { echo "missing $d/bin/busybox — run ./build.sh first" >&2; exit 1; }
done
# Each slice keeps its own LC_BUILD_VERSION, so differing minimums are fine and
# expected (arm64 cannot go below 11.0; x86_64 can be older). Just report them.
ma=$(otool -l -arch arm64  "$A/bin/busybox" | grep -A4 -E 'LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX' | grep -oE '(minos|version) [0-9.]+' | head -1)
mb=$(otool -l -arch x86_64 "$B/bin/busybox" | grep -A4 -E 'LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX' | grep -oE '(minos|version) [0-9.]+' | head -1)

rm -rf "$OUT"
cp -R "$A" "$OUT"              # keep the symlink farm (relative links still resolve)
rm -f "$OUT/bin/busybox"
lipo -create -output "$OUT/bin/busybox" "$A/bin/busybox" "$B/bin/busybox"
# lipo output is unsigned for arm64; re-apply the ad-hoc signature it requires.
codesign -s - --force "$OUT/bin/busybox" 2>/dev/null || true

echo "universal2: $OUT/bin/busybox"
echo "  archs:  $(lipo -archs "$OUT/bin/busybox")"
echo "  minos:  arm64 $ma / x86_64 $mb"
echo "  size:   $(stat -f%z "$OUT/bin/busybox") bytes"
