#!/bin/bash
# 50 checks on the reaper: the watchdog that kills a command's process group when
# the busybox wrapper dies.
#
#   ./tests/reaper.sh dist/darwin-arm64/bin/busybox
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 \
#       bash /w/tests/reaper.sh /w/dist/linux-arm64/bin/busybox
set -u
BB="${1:?usage: reaper.sh /path/to/busybox}"
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
		printf 'FAIL %-52s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}
sec() { printf '== %s ==\n' "$1"; }

if ! "$BB" --list | "$BB" grep -qx run; then
	echo "skip: run applet not in this build"
	exit 0
fi

alive() { kill -0 "$1" 2>/dev/null; }

# Launch the wrapper in the FOREGROUND (bash gives background jobs SIGINT
# ignored), have a helper signal it once the guest publishes its pid.
# $1 wrapper run|sh, $2 signal, $3 guest body, $4 unique tag
probe() {
	local wrapper="$1" sig="$2" body="$3" tag="$4"
	local pidf="$T/p.$tag" target g i
	rm -f "$pidf"
	(
		i=0
		while [ ! -s "$pidf" ] && [ "$i" -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
		if [ "$wrapper" = run ]; then target=$(sed -n 2p "$pidf"); else target=$(sed -n 1p "$pidf"); fi
		[ -n "$target" ] && kill -"$sig" "$target" 2>/dev/null
		# Unblock the foreground wrapper if the signal was ignored, so a failed
		# expectation reports "alive" instead of hanging the suite.
		sleep 3
		kill -9 "$target" 2>/dev/null
	) &
	local helper=$!
	if [ "$wrapper" = run ]; then
		"$BB" run --dir "$T/d.$tag" --quiet -- sh -c "PIDF=$pidf; echo \$\$ > \$PIDF; echo \$PPID >> \$PIDF; $body" >/dev/null 2>&1
	else
		"$BB" sh -c "PIDF=$pidf; echo \$\$ > \$PIDF; echo \$PPID >> \$PIDF; $body" >/dev/null 2>&1
	fi
	wait "$helper" 2>/dev/null
	g=$(sed -n 1p "$pidf" 2>/dev/null)
	if [ -z "$g" ]; then
		echo "no-pid"
		return
	fi
	i=0
	while [ "$i" -lt 40 ]; do
		alive "$g" || break
		sleep 0.05
		i=$((i + 1))
	done
	if alive "$g"; then
		echo "alive"
		kill -9 "$g" 2>/dev/null
	else
		echo "gone"
	fi
	wait 2>/dev/null
}

G_EXEC='exec sleep 30'                                   # plain guest
G_STUBBORN="trap '' TERM INT HUP QUIT; exec sleep 30"    # ignores everything catchable
G_GRANDCHILD="sh -c 'trap \"\" TERM; sleep 30' & echo \$! >> \$PIDF; exec sleep 30"
G_CHILD='sleep 30 & echo $! >> $PIDF; wait'              # background child
G_SPIN="trap '' TERM; while :; do :; done"               # CPU spin, ignores TERM
G_SPIN_CHILD="sh -c 'trap \"\" TERM; while :; do :; done' & echo \$! >> \$PIDF; wait"

sigs="TERM INT HUP QUIT KILL"

# ------------------------------------------------ A. run, five signals
sec "A. run"
for s in $sigs; do
	ck "run.$s.exec"       "gone" "$(probe run "$s" "$G_EXEC" "a1$s")"
	ck "run.$s.stubborn"   "gone" "$(probe run "$s" "$G_STUBBORN" "a2$s")"
	ck "run.$s.grandchild" "gone" "$(probe run "$s" "$G_GRANDCHILD" "a3$s")"
done

# ------------------------------------------------- B. sh, five signals
sec "B. sh"
for s in $sigs; do
	ck "sh.$s.exec"   "gone" "$(probe sh "$s" "$G_EXEC" "b1$s")"
	ck "sh.$s.child"  "gone" "$(probe sh "$s" "$G_CHILD" "b2$s")"
	ck "sh.$s.spin_child" "gone" "$(probe sh "$s" "$G_SPIN_CHILD" "b3$s")"
done

# ------------------------------------------- C. the reaper itself
sec "C. reaper hygiene"
tag=cn1; "$BB" run --dir "$T/d.$tag" --quiet -- echo done >/dev/null 2>&1
sleep 0.4
ck "run.no_reaper_after_success" "0" "$("$BB" pgrep -f "d.$tag" 2>/dev/null | "$BB" wc -l | tr -d ' ')"
tag=cn2; "$BB" sh -c 'echo done' >/dev/null 2>&1
sleep 0.4
ck "sh.no_reaper_after_success"  "0" "$("$BB" pgrep -f "sh -c echo done" 2>/dev/null | "$BB" wc -l | tr -d ' ')"
ck "run.output_intact"  "hi"  "$("$BB" run --quiet -- echo hi 2>/dev/null)"
ck "sh.output_intact"   "ok"  "$("$BB" sh -c 'echo ok' 2>/dev/null)"
tag=ck1; ( "$BB" run --dir "$T/d.$tag" --quiet -- exec sleep 30 >/dev/null 2>&1 ) & w=$!
sleep 0.5; kill -9 $w 2>/dev/null; sleep 1
ck "run.no_reaper_after_kill" "0" "$("$BB" pgrep -f "d.$tag" 2>/dev/null | "$BB" wc -l | tr -d ' ')"
tag=ck2; ( "$BB" sh -c 'sleep 30 & wait' >/dev/null 2>&1 ) & w=$!
sleep 0.5; kill -9 $w 2>/dev/null; sleep 1
ck "sh.no_reaper_after_kill"  "0" "$("$BB" pgrep -f "sh -c sleep 30" 2>/dev/null | "$BB" wc -l | tr -d ' ')"
wait 2>/dev/null
ck "run.json_has_run_id" "1"  "$("$BB" run --format json -- true | "$BB" grep -c '"run":"R')"
ck "run.json_pgid"       "1"  "$("$BB" run --format json -- true | "$BB" grep -c '"pgid":')"

# ---------------------------------------- D. the reaper does not fire early
sec "D. no premature kill"
pidf="$T/d1"; rm -f "$pidf"
( "$BB" run --dir "$T/dd1" --quiet -- sh -c "PIDF=$pidf; echo \$\$ > \$PIDF; sleep 2" >/dev/null 2>&1 ) &
w=$!
i=0; while [ ! -s "$pidf" ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
ck "run.guest_alive_while_wrapper_lives" "true" "$(alive "$(cat "$pidf")" && echo true || echo false)"
wait $w 2>/dev/null

pidf="$T/d2"; rm -f "$pidf"
( "$BB" sh -c "PIDF=$pidf; echo \$\$ > \$PIDF; sleep 2 & echo \$! >> \$PIDF; wait" >/dev/null 2>&1 ) &
w=$!
i=0; while [ ! -s "$pidf" ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
ck "sh.child_alive_while_wrapper_lives" "true" "$(alive "$(sed -n 2p "$pidf")" && echo true || echo false)"
wait $w 2>/dev/null

ck "run.exit_code_passthrough" "7" "$("$BB" run --quiet -- sh -c 'exit 7' >/dev/null 2>&1; echo $?)"
ck "sh.exit_code_passthrough"  "9" "$("$BB" sh -c 'exit 9' >/dev/null 2>&1; echo $?)"
ck "run.timeout_still_3"       "3" "$("$BB" run --timeout 0.3 -- sh -c 'sleep 5' >/dev/null 2>&1; echo $?)"
ck "sh.timeout_still_3"        "3" "$("$BB" sh --timeout 1 -c 'sleep 5' >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------- E. nesting
sec "E. nested wrappers"
pidf="$T/e1"; rm -f "$pidf"
( "$BB" sh -c "PIDF=$pidf; echo \$\$ > \$PIDF; echo \$PPID >> \$PIDF; $BB run --quiet -- sh -c 'echo \$\$ >> \$PIDF; sleep 30 & echo \$! >> \$PIDF; wait'" >/dev/null 2>&1 ) &
w=$!
i=0; while [ "$(wc -l < "$pidf" 2>/dev/null || echo 0)" -lt 3 ] && [ "$i" -lt 80 ]; do sleep 0.05; i=$((i + 1)); done
inner=$(sed -n 3p "$pidf")
kill -9 "$w" 2>/dev/null
sleep 0.8
ck "nested.sh_killed_inner_gone" "false" "$(alive "$inner" && echo true || echo false)"
wait 2>/dev/null

pidf="$T/e2"; rm -f "$pidf"
( "$BB" run --dir "$T/de2" --quiet -- sh -c "PIDF=$pidf; echo \$\$ > \$PIDF; echo \$PPID >> \$PIDF; $BB sh -c 'echo \$\$ >> \$PIDF; sleep 30 & echo \$! >> \$PIDF; wait'" >/dev/null 2>&1 ) &
w=$!
i=0; while [ "$(wc -l < "$pidf" 2>/dev/null || echo 0)" -lt 3 ] && [ "$i" -lt 80 ]; do sleep 0.05; i=$((i + 1)); done
inner=$(sed -n 3p "$pidf")
kill -9 "$w" 2>/dev/null
sleep 0.8
ck "nested.run_killed_inner_gone" "false" "$(alive "$inner" && echo true || echo false)"
wait 2>/dev/null

# ------------------------------------------------------- F. concurrency
sec "F. three at once"
pids=""
for n in 1 2 3; do
	pidf="$T/f$n"; rm -f "$pidf"
	( "$BB" run --dir "$T/df$n" --quiet -- sh -c "PIDF=$pidf; echo \$\$ > \$PIDF; echo \$PPID >> \$PIDF; exec sleep 30" >/dev/null 2>&1 ) &
	eval "w$n=$!"
done
i=0; while [ "$i" -lt 60 ]; do [ -s "$T/f1" ] && [ -s "$T/f2" ] && [ -s "$T/f3" ] && break; sleep 0.05; i=$((i + 1)); done
for n in 1 2 3; do eval "kill -9 \$w$n 2>/dev/null"; done
sleep 1
for n in 1 2 3; do
	g=$(sed -n 1p "$T/f$n" 2>/dev/null)
	ck "concurrent.$n.guest_gone" "false" "$(alive "$g" && echo true || echo false)"
done
ck "concurrent.no_stray_guest" "0" "$(for n in 1 2 3; do sed -n 1p "$T/f$n" 2>/dev/null; done | while read -r p; do alive "$p" && echo x; done | "$BB" grep -c .)"
wait 2>/dev/null

printf '== reaper: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
