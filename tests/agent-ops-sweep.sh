#!/bin/bash
# Option-space and composition sweep for the agent-facing applets.
#
#   ./tests/agent-ops-sweep.sh build/deep-darwin/busybox
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 \
#       bash /w/tests/agent-ops-sweep.sh /w/build/deep-linux-arm64/busybox
#
# tests/agent-ops-deep.sh walks the *input* space; this one walks the *option*
# space and the seams between applets:
#
#   - every documented short option must equal its long form, byte for byte;
#   - byte budgets must be monotone and never exceeded;
#   - one applet's output must be another applet's valid input (peek ->
#     replace -> peek --diff, run -> log, snapshot -> snapshot --diff);
#   - a malformed option must leave the filesystem alone and exit 2.
#
# Everything runs through $BB; no host tool beyond the shell is assumed.
set -u
BB="${1:?usage: agent-ops-sweep.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[ -x "$BB" ] || { echo "not executable: $BB" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"

pass=0 fail=0 skips=0
ck() {
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL %-58s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}
skip() { skips=$((skips + 1)); printf 'skip %s\n' "$1"; }
sec() { printf '== %s ==\n' "$1"; }
rc() { "$@" > "$T/out" 2> "$T/err"; echo $?; }
is_ok_code() { case "$1" in 0|1|2|3) echo 1 ;; *) echo 0 ;; esac; }
ckrc() { ck "$1" "1" "$(is_ok_code "$2")"; }
# same output AND same status for two command forms
same() { # same <name> <short-cmd...> -- <long-cmd...>
	name=$1; shift
	"$@" > "$T/s.out" 2> "$T/s.err"; s=$?
	set -- $(printf '%s' "")
}
EOF_MARK=1
