#!/bin/bash
# Map failing source files to kconfig symbols, then disable them in a build .config.
# Usage: ./prune/fail2conf.sh <builddir>
# Prints "source -> CONFIG symbols" for every file that fails to compile.
# Feed the CONFIG names into a disable list (see darwin-off.txt).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src"
BUILD="${1:?usage: fail2conf.sh <builddir>}"

LOG="$(mktemp)"
cd "$ROOT"
# -k keeps going; collect failing source files
make -C "$SRC" O="$BUILD" -k -j8 CC="cc -arch arm64" HOSTCC=cc >"$LOG" 2>&1

grep -oE "$SRC/[a-zA-Z0-9_-]+/[A-Za-z0-9_.-]+\.c" "$LOG" | sort -u | while read -r f; do
  rel="${f#"$SRC"/}"
  syms=$(grep -oE 'IF_[A-Z0-9_]+|CONFIG_[A-Z0-9_]+' "$f" 2>/dev/null | sed -E 's/^IF_/CONFIG_/' | sort -u | tr '\n' ' ')
  echo "$rel -> $syms"
done
