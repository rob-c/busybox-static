#!/bin/bash
# Killing busybox must kill what it forked.
#
#   ./tests/wrapper-signals.sh dist/darwin-arm64/bin/busybox
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 \
#       bash /w/tests/wrapper-signals.sh /w/dist/linux-arm64/bin/busybox
#
# `run` and `sh` start a watchdog child in its own process group that kills the
# command's group when the wrapper disappears for ANY reason — SIGKILL included,
# which cannot be caught. These checks signal the wrapper and then ask whether
# the command is still alive, using pid files and `kill -0` so an exec()ed guest
# cannot hide from the scan.
set -u
BB="${1:?usage: wrapper-signals.sh /path/to/busybox}"
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
		printf 'FAIL %-50s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}
sec() { printf '== %s ==\n' "$1"; }

if ! "$BB" --list | "$BB" grep -qx run; then
	echo "skip: run applet not in this build"
	exit 0
fi

alive() { kill -0 "$1" 2>/dev/null; }

# Start a wrapper whose guest records its own pid, signal the wrapper, then
# report whether the guest survived. $1 wrapper (run|sh), $2 signal,
# $3 guest body (must write /tmp pid file via $PIDF).
probe() { # probe <run|sh> <signal> <guest body>  -> "gone" | "alive" | "no-pid"
	local wrapper="$1" sig="$2" body="$3" pidf="$T/pids.$1.$2" target
	rm -f "$pidf"

	# The wrapper runs in the FOREGROUND (a backgrounded child inherits SIGINT
	# ignored, which would make an INT probe meaningless); a helper signals it
	# once the guest has published its pids. Line 1 is the guest's own pid, line
	# 2 is its parent — for `run` that parent is the wrapper, for `sh` the shell
	# itself is the wrapper.
	(
		i=0
		while [ ! -s "$pidf" ] && [ "$i" -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
		if [ "$wrapper" = run ]; then
			t=$(sed -n 2p "$pidf")
		else
			t=$(sed -n 1p "$pidf")
		fi
		[ -n "$t" ] && kill -"$sig" "$t" 2>/dev/null
	) &
	local helper=$!

	if [ "$wrapper" = run ]; then
		"$BB" run --quiet -- sh -c "PIDF=$pidf; echo \$\$ > \$PIDF; echo \$PPID >> \$PIDF; $body" >/dev/null 2>&1
	else
		"$BB" sh -c "PIDF=$pidf; echo \$\$ > \$PIDF; echo \$PPID >> \$PIDF; $body" >/dev/null 2>&1
	fi
	local w=$!
	wait "$helper" 2>/dev/null

	local g i=0
	g=$(sed -n 1p "$pidf" 2>/dev/null)
	if [ -z "$g" ]; then
		echo "no-pid"
		return
	fi
	while [ "$i" -lt 40 ]; do
		alive "$g" || break
		sleep 0.05
		i=$((i + 1))
	done
	if alive "$g"; then echo "alive"; kill -9 "$g" 2>/dev/null; else echo "gone"; fi
	wait 2>/dev/null
}

# ---------------------------------------------------------------- A. run
sec "A. run: kill busybox, kill the command"
ck "run.term.guest_gone"   "gone" "$(probe run TERM 'exec sleep 30')"
ck "run.int.guest_gone"    "gone" "$(probe run INT  'exec sleep 30')"
ck "run.hup.guest_gone"    "gone" "$(probe run HUP  'exec sleep 30')"
ck "run.kill.guest_gone"   "gone" "$(probe run KILL 'exec sleep 30')"

sec "A2. run: a guest that ignores TERM still goes"
ck "run.kill.guest_ignores_term" "gone" "$(probe run KILL "trap '' TERM; exec sleep 30")"
ck "run.term.guest_ignores_term" "gone" "$(probe run TERM "trap '' TERM; exec sleep 30")"

sec "A3. run: grandchildren go too"
ck "run.kill.grandchild_gone" "gone" "$(probe run KILL "sh -c 'sleep 30' & echo \$! >> \$PIDF; exec sleep 30")"
ck "run.term.grandchild_gone" "gone" "$(probe run TERM "sh -c 'sleep 30' & echo \$! >> \$PIDF; exec sleep 30")"

# ---------------------------------------------------------------- B. sh
sec "B. sh: kill busybox, kill the command"
ck "sh.term.guest_gone"    "gone" "$(probe sh TERM 'exec sleep 30')"
ck "sh.int.guest_gone"     "gone" "$(probe sh INT  'exec sleep 30')"
ck "sh.hup.guest_gone"     "gone" "$(probe sh HUP  'exec sleep 30')"
ck "sh.kill.guest_gone"    "gone" "$(probe sh KILL 'exec sleep 30')"

sec "B2. sh: background children and traps"
ck "sh.kill.child_gone"    "gone" "$(probe sh KILL 'sleep 30 & echo $! >> $PIDF; wait')"
ck "sh.term.child_gone"    "gone" "$(probe sh TERM 'sleep 30 & echo $! >> $PIDF; wait')"
ck "sh.kill.ignoring_child" "gone" "$(probe sh KILL "sh -c 'trap \"\" TERM; sleep 30' & echo \$! >> \$PIDF; wait")"

# ------------------------------------------------------- C. nothing broken
sec "C. ordinary behaviour is untouched"
ck "run.exit_code_passthrough" "7" "$("$BB" run --quiet -- sh -c 'exit 7' >/dev/null 2>&1; echo $?)"
ck "run.output_passthrough"    "hi" "$("$BB" run --quiet -- echo hi 2>/dev/null)"
ck "sh.exit_code_passthrough"  "9" "$("$BB" sh -c 'exit 9' >/dev/null 2>&1; echo $?)"
ck "sh.output_passthrough"     "ok" "$("$BB" sh -c 'echo ok' 2>/dev/null)"
ck "run.no_watchdog_left"      "0"  "$("$BB" run --quiet -- true >/dev/null 2>&1; "$BB" pgrep -c -f 'busybox run --quiet -- true' 2>/dev/null || echo 0)"
ck "sh.no_watchdog_left"       "0"  "$("$BB" sh -c true >/dev/null 2>&1; "$BB" pgrep -c -f 'busybox sh -c true' 2>/dev/null || echo 0)"

printf '== wrapper-signals: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
