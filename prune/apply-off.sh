#!/bin/bash
# Turn off CONFIG symbols listed in a file inside a busybox .config,
# then re-run oldconfig so dependencies are honoured.
# Usage: apply-off.sh <builddir> <symlist>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${1:?usage: apply-off.sh <builddir> <symlist>}"
LIST="${2:?usage: apply-off.sh <builddir> <symlist>}"
CFG="$BUILD/.config"

grep -vE '^\s*(#|$)' "$LIST" | while read -r sym; do
  sym="${sym%% *}"
  # canonical "disabled" form; if the symbol is selected/not present this is a no-op
  sed -i '' -e "s|^${sym}=.*|# ${sym} is not set|" \
            -e "s|^# ${sym} is not set|# ${sym} is not set|" "$CFG"
done

make -C "$ROOT/src" O="$BUILD" oldconfig </dev/null >/dev/null 2>&1 || true
echo "applied $(grep -cvE '^\s*(#|$)' "$LIST") disable rules to $CFG"
