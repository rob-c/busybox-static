#!/bin/bash
# Deadline resilience, matrix edition: 200 checks over 10 hostile guests and 4
# ways of invoking them. Where tests/timeout-resilience.sh names each scenario,
# this file multiplies them, so a regression in one path cannot hide behind a
# happy-path neighbour.
#
#   ./tests/timeout-resilience-matrix.sh dist/darwin-arm64/bin/busybox
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 \
#       bash /w/tests/timeout-resilience-matrix.sh /w/dist/linux-arm64/bin/busybox
#
# Each combination asserts five things: the wrapper exits 3, it is never 124,
# it is never 128+N, no guest process survives, and the whole thing finished
# within the deadline plus a generous grace window.
set -u
BB="${1:?usage: timeout-resilience-matrix.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[ -x "$BB" ] || { echo "not executable: $BB" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"

pass=0 fail=0
ck() { # ck <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL %-56s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}

# procps wants `args`, BSD/macOS wants `command`; pick whichever works here.
PSF=""
if ps -A -o args= >/dev/null 2>&1; then PSF="args"
elif ps -A -o command= >/dev/null 2>&1; then PSF="command"
fi

if ! "$BB" --list | "$BB" grep -qx run; then
	echo "skip: run applet not in this build"
	exit 0
fi
if [ ! -d /proc/self ] && [ -z "$PSF" ]; then
	echo "skip: no process table (/proc absent and no usable ps)"
	exit 0
fi

# The harness must never look like a guest: filter its own helpers out.
# Survivors are tracked by PID FILE, not by scanning command lines: a guest whose
# last command is `sleep 30` gets exec()ed, so the marker disappears from its
# argv on Linux and a cmdline scan goes blind. Every guest records its own pid
# (and any child pid) before blocking; a PID is a survivor if `kill -0` still
# succeeds after the wrapper returned.
survivors() { # survivors <pidfile> -> count of live pids
	local p n=0
	[ -f "$1" ] || { echo 0; return; }
	while read -r p; do
		[ -n "$p" ] || continue
		if kill -0 "$p" 2>/dev/null; then
			# a zombie is already dead; /proc state Z means reaped-by-nobody
			if [ -r "/proc/$p/stat" ]; then
				case "$(cut -d' ' -f3 "/proc/$p/stat" 2>/dev/null)" in
				Z) continue ;;
				esac
			fi
			n=$((n + 1))
		fi
	done < "$1"
	echo "$n"
}
sweep() { # sweep <pidfile>
	local p
	[ -f "$1" ] || return 0
	while read -r p; do
		[ -n "$p" ] && kill -9 "$p" 2>/dev/null
	done < "$1"
	return 0
}

# 10 guests. Every one either traps a fatal signal, ignores several, or leaves a
# descendant doing the same. Each starts by echoing its marker so the process
# scan can find it.
guests=(
	"trap '' TERM; sleep 30"                        # ignore TERM
	"trap '' TERM INT; sleep 30"                    # ignore TERM+INT
	"trap '' TERM INT HUP QUIT; sleep 30"           # ignore four
	"trap 'sleep 30' TERM; sleep 30"                # trap that blocks in the handler
	"trap 'exit 0' TERM; sleep 30"                  # pretend compliance
	"trap 'exit 3' TERM; sleep 30"                  # exit with the timeout code
	"sh -c 'trap \"\" TERM; sleep 30' & echo \$! >> \$PIDF; wait"  # child ignores
	"( trap '' TERM; sleep 30 ) & echo \$! >> \$PIDF; sleep 30"  # subshell ignores
	"trap '' TERM; for i in 1 2 3; do sleep 30; done"
	"trap '' TERM; while :; do :; done"             # CPU spin, no syscalls
)

run_case() { # run_case <which> <script> -> RC, OUT, SECONDS delta
	local which="$1" script="$2" start=$SECONDS
	case "$which" in
	run-json) OUT=$("$BB" run --format json --timeout 1 -- sh -c "$script" 2>/dev/null); RC=$? ;;
	run-kill) OUT=$("$BB" run --timeout 1 --kill-after 0.2 -- sh -c "$script" 2>/dev/null); RC=$? ;;
	sh)       OUT=$("$BB" sh --timeout 1 -c "$script" 2>/dev/null); RC=$? ;;
	run-brief) OUT=$("$BB" run --quiet --timeout 1 --brief stdout -- sh -c "$script" 2>/dev/null); RC=$? ;;
	esac
	ELAPSED=$((SECONDS - start))
}

whichs="run-json run-kill sh run-brief"
gi=0
for g in "${guests[@]}"; do
	gi=$((gi + 1))
	MARK="m${gi}g"
	PIDF="$T/pids.$MARK"
	rm -f "$PIDF"
	script="PIDF=$PIDF; export PIDF; echo \$\$ >> \$PIDF; $g"
	for w in $whichs; do
		run_case "$w" "$script"
		tag="$w.g$gi"
		ck "$tag.rc3"          "3"     "$RC"
		ck "$tag.not124"       "no"    "$([ "$RC" = 124 ] && echo yes || echo no)"
		ck "$tag.not128plus"   "no"    "$([ "$RC" -ge 128 ] && echo yes || echo no)"
		sleep 0.2
		ck "$tag.no_survivor"  "0"     "$(survivors "$PIDF")"
		sweep "$PIDF"
		ck "$tag.within_grace" "no"    "$([ "$ELAPSED" -gt 8 ] && echo yes || echo no)"
	done
done

printf '== timeout-resilience-matrix: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
