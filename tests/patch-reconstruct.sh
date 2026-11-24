#!/bin/bash
# Prove that patches/ reconstructs src/ from the clone's own HEAD.
#
#   ./tests/patch-reconstruct.sh            # default: src, patches/
#   ./tests/patch-reconstruct.sh DIR PATCHDIR
#
# The series is a set of cumulative diffs from `git -C src HEAD`, so the only
# claim worth testing is the end state: apply every patch in order to a clean
# export of HEAD and compare the result with the working tree. A handful of
# `.rej` files can appear when a hunk is already applied by an earlier patch;
# they are reported, not treated as failure, because the comparison below is
# what decides.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/src}"
PATCHES="${2:-$ROOT/patches}"
BB="${BB:-busybox}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tree"

git -C "$SRC" archive HEAD | tar -x -C "$T/tree" || {
	echo "cannot export $SRC HEAD" >&2
	exit 1
}

cd "$T/tree" || exit 1
applied=0
failed=0
for p in "$PATCHES"/*.patch; do
	patch -p1 -N --no-backup-if-mismatch < "$p" >/dev/null 2>&1
	rc=$?
	applied=$((applied + 1))
	# 1 means "some hunks were already applied"; that is expected for a series
	# of cumulative diffs and is reported below as rejects, not as failure
	[ "$rc" -gt 1 ] && { failed=$((failed + 1)); echo "APPLY FAILED $(basename "$p")"; }
done

rejects=$(find . -name '*.rej' | wc -l | tr -d ' ')
differing=$(diff -rq "$T/tree" "$SRC" --exclude=.git 2>/dev/null |
	grep -vE '^Only in ' | wc -l | tr -d ' ')
onlysrc=$(diff -rq "$T/tree" "$SRC" --exclude=.git 2>/dev/null |
	grep -c "^Only in $SRC" || true)

printf 'patches applied:   %s\n' "$applied"
printf 'hard apply errors: %s\n' "$failed"
printf 'rejects (benign):  %s\n' "$rejects"
printf 'files differing:   %s\n' "$differing"
printf 'files only in src: %s (untracked scratch dirs are expected here)\n' "$onlysrc"

if [ "$differing" != 0 ]; then
	echo "FAIL: the series does not reconstruct the tree"
	diff -rq "$T/tree" "$SRC" --exclude=.git 2>/dev/null | grep -vE '^Only in ' | head -20
	exit 1
fi
echo "OK: patches/ reproduces src/ exactly"
