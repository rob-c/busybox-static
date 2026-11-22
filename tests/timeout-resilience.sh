#!/bin/bash
# Deadline resilience: 50 checks that `run --timeout` and `sh --timeout` still
# end on time when the guest command catches, ignores or outlives signals.
#
#   ./tests/timeout-resilience.sh dist/darwin-arm64/bin/busybox
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 \
#       bash /w/tests/timeout-resilience.sh /w/dist/linux-arm64/bin/busybox
#
# Every guest is a shell one-liner and the only host tool used is `ps`, so the
# same file runs on Darwin and on Linux/musl. Process-list checks skip (never
# fail) where `ps -A -o command=` is unavailable.
set -u
BB="${1:?usage: timeout-resilience.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[ -x "$BB" ] || { echo "not executable: $BB" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"

pass=0 fail=0 skips=0
ck() { # ck <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL %-52s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}
skipck() { skips=$((skips + 1)); printf 'skip %s\n' "$1"; }
sec() { printf '== %s ==\n' "$1"; }

if ! "$BB" --list | "$BB" grep -qx run; then
	echo "skip: run applet not in this build"
	exit 0
fi

jrun() { # jrun ARGS... -> OUT (json payload), RC
	OUT=$("$BB" run --format json "$@" 2>/dev/null)
	RC=$?
}
jf() { printf '%s' "$OUT" | sed -n "s/.*\"$1\":\([^,}]*\).*/\1/p" | head -1 | sed 's/^"//; s/"$//'; }

have_ps() { ps -A -o command= >/dev/null 2>&1; }
# The harness itself must never look like a guest: filter the shell pipeline,
# this script, and the ps/awk/grep helpers out of the process list.
alive() { # alive <marker>
	ps -A -o command= 2>/dev/null |
		"$BB" grep -F -- "$1" |
		"$BB" grep -v -e awk -e grep -e 'ps -A' -e timeout-resilience |
		"$BB" grep -q .
}
sweep() { # kill leftovers so one failure cannot poison the next check
	local p
	ps -A -o pid=,command= 2>/dev/null |
		"$BB" grep -F -- "$1" |
		"$BB" grep -v -e awk -e grep -e 'ps -A' -e timeout-resilience |
		"$BB" awk -v self="$$" '{ if ($1 != self) print $1 }' |
		while read -r p; do kill -9 "$p" 2>/dev/null; done
}
orphan_ck() { # orphan_ck <name> <marker>
	if have_ps; then
		sweep "$2"; sleep 0.4
		ck "$1" "false" "$(alive "$2" && echo true || echo false)"
	else
		skipck "$1"
	fi
}

# ------------------------------------------------------- A. baseline
sec "A. baseline deadline"
jrun --timeout 1 -- sh -c 'echo up; sleep 30'
ck "run.baseline.rc"             "3"     "$RC"
ck "run.baseline.timed_out"      "true"  "$(jf timed_out)"
ck "run.baseline.capture"        "true"  "$(jf capture_complete)"
ck "run.baseline.stdout_kept"    "up"    "$(printf '%s' "$(jf stdout_view)" | tr -d '\\n')"
ck "run.baseline.killed_signal"  "true"  "$([ "$(jf exit_code)" -lt 0 ] && echo true || echo false)"

jrun --timeout 1 --kill-after 1 -- sh -c 'echo up; sleep 30'

# ------------------------------- B. the guest refuses to die politely
sec "B. guest traps TERM and keeps running"
MARK=$(printf 'tb%s' 1)
jrun --timeout 1 -- sh -c "trap '' TERM; echo $MARK; echo start; while :; do sleep 1; done"
ck "trap-term.rc"                "3"     "$RC"
ck "trap-term.timed_out"         "true"  "$(jf timed_out)"
ck "trap-term.capture"           "true"  "$(jf capture_complete)"
ck "trap-term.early_output_kept" "start" "$(printf '%s' "$(jf stdout_view)" | tr -d '\\n' | tail -c 5)"
ck "trap-term.killed_by_signal"  "true"  "$([ "$(jf exit_code)" -lt 0 ] && echo true || echo false)"
orphan_ck "trap-term.no_orphan" "$MARK"

sec "B2. guest traps TERM and exits 0"
jrun --timeout 1 -- sh -c "trap 'exit 0' TERM; sleep 30; echo tail"
ck "trap-exit0.rc"               "3"     "$RC"
ck "trap-exit0.timed_out"        "true"  "$(jf timed_out)"
ck "trap-exit0.not_success"      "true"  "$([ "$RC" = 0 ] && echo false || echo true)"
ck "trap-exit0.no_tail"          "0"     "$(printf '%s' "$(jf stdout_view)" | "$BB" grep -c tail)"

sec "B3. guest ignores TERM, INT and HUP"
MARK=$(printf 'tb%s' 3)
jrun --timeout 1 -- sh -c "trap '' TERM INT HUP; echo $MARK; sleep 30"
ck "ignore3.rc"                  "3"     "$RC"
ck "ignore3.timed_out"           "true"  "$(jf timed_out)"
orphan_ck "ignore3.no_orphan"    "$MARK"

# ------------------------------------- C. grandchildren resist as well
sec "C. grandchild ignores TERM"
MARK=$(printf 'tc%s' 1)
jrun --timeout 1 -- sh -c "sh -c 'trap \"\" TERM; echo $MARK; sleep 30' & sleep 30"
ck "grandchild.rc"               "3"     "$RC"
ck "grandchild.timed_out"        "true"  "$(jf timed_out)"
orphan_ck "grandchild.no_orphan" "$MARK"

sec "C2. --kill-after tightens the grace window"
jrun --timeout 1 --kill-after 0.2 -- sh -c "trap '' TERM; sleep 30"
ck "kill-after.rc"               "3"     "$RC"
ck "kill-after.timed_out"        "true"  "$(jf timed_out)"
ck "kill-after.neg_exit"         "true"  "$([ "$(jf exit_code)" -lt 0 ] && echo true || echo false)"

# ---------------------------------------------------------- D. via sh
sec "D. sh --timeout"
OUT=$("$BB" sh --timeout 1 -c 'echo up; sleep 30' 2>/dev/null); RC=$?
ck "sh.rc"                       "3"     "$RC"
ck "sh.output_kept"              "up"    "$(printf '%s' "$OUT" | head -1)"
OUT=$("$BB" sh --timeout 1 -c "trap '' TERM; echo x; sleep 30" 2>/dev/null); RC=$?
ck "sh.ignore-term.rc"           "3"     "$RC"
OUT=$("$BB" sh --timeout 5 -c 'echo fast; exit 5' 2>/dev/null); RC=$?
ck "sh.passthrough.rc"           "5"     "$RC"
ck "sh.passthrough.out"          "fast"  "$(printf '%s' "$OUT" | head -1)"
OUT=$("$BB" sh --timeout 1 2>/dev/null); RC=$?
ck "sh.no_command.rc"            "2"     "$RC"

printf 'echo script-up\nsleep 30\n' > "$T/s.sh"
OUT=$("$BB" sh --timeout 1 "$T/s.sh" 2>/dev/null); RC=$?
ck "sh.script.rc"                "3"     "$RC"
ck "sh.script.out"               "script-up" "$(printf '%s' "$OUT" | head -1)"

# --------------------------------- D2. sub-second and repeated deadlines
sec "E. sub-second and repeated deadlines"
jrun --timeout 0.05 -- sh -c 'sleep 5'
ck "e.subsecond.rc"              "3"     "$RC"
ck "e.subsecond.timed_out"       "true"  "$(jf timed_out)"
jrun --timeout 1 -- sh -c 'trap "" TERM; sleep 5'
ck "e.repeat1"                   "3"     "$RC"
jrun --timeout 1 -- sh -c 'trap "" TERM; sleep 5'
ck "e.repeat2"                   "3"     "$RC"
jrun --timeout 1 -- sh -c 'trap "" TERM; sleep 5'
ck "e.repeat3"                   "3"     "$RC"

# ---------------------------------------- F. deadline holds with --brief
sec "F. brief inside a deadline"
jrun --timeout 1 --brief stdout -- sh -c 'for i in 1 2 3; do echo same; done; sleep 30'
ck "brief-timeout.rc"            "3"     "$RC"
ck "brief-timeout.timed_out"     "true"  "$(jf timed_out)"
ck "brief-timeout.merged"        "3"     "$(printf '%s' "$(jf stdout_view)" | sed -n 's/.*\([0-9][0-9]*\)x same.*/\1/p' | head -1)"
OUT=$("$BB" run --quiet --timeout 1 --brief stdout --brief-json -- sh -c 'for i in 1 2; do echo d; done; sleep 30' 2>/dev/null); RC=$?
ck "brief-json-timeout.rc"       "3"     "$RC"
ck "brief-json-timeout.records"  "1"     "$(printf '%s' "$OUT" | sed -n 's/.*"records":\([0-9][0-9]*\).*/\1/p' | head -1)"

# --------------------------------------------- G. repetition and taxonomy
sec "G. repetition"
i=0; bad=0
while [ "$i" -lt 5 ]; do
	jrun --timeout 1 -- sh -c 'trap "" TERM; sleep 5'
	[ "$RC" = 3 ] || bad=$((bad + 1))
	i=$((i + 1))
done
ck "repeat.five_rc3"             "0"     "$bad"
"$BB" log R1 --format json >/dev/null 2>&1

sec "H. exit-code taxonomy"
jrun --timeout 5 -- sh -c 'exit 7'
ck "h.fast_child_rc"             "7"     "$RC"
ck "h.fast_child_exit_code"      "7"     "$(jf exit_code)"
jrun --timeout 0.5 -- sh -c 'sleep 9'
ck "h.timeout_rc3"               "3"     "$RC"
jrun --timeout 1 -- /nonexistent/prog
ck "h.spawn_fail_rc"             "1"     "$RC"
ck "h.spawn_fail_code"           "SPAWN_FAILED" "$(jf code | tr -d '"' | sed 's/}.*//')"
ck "h.zero_timeout_rc"           "3"     "$("$BB" run --timeout 0 -- sh -c 'sleep 2' >/dev/null 2>&1; echo $?)"
ck "h.child_signal_rc1"          "1"     "$("$BB" run -- sh -c 'kill -TERM $$' >/dev/null 2>&1; echo $?)"

printf '== timeout-resilience: %d passed, %d failed, %d skipped ==\n' "$pass" "$fail" "$skips"
[ "$fail" -eq 0 ]
