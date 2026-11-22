#!/bin/bash
# Stream discipline for every applet, and the opt-in diagnostic ids.
#
#   ./tests/streams.sh dist/darwin-arm64/bin/busybox
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 bash /w/tests/streams.sh \
#       /w/dist/linux-arm64/bin/busybox
#
# Two properties:
#
#   1. a diagnostic goes to stderr and nowhere else - checked by sweeping every
#      applet with an argument it must reject, and requiring stdout to be empty;
#   2. with BUSYBOX_ERROR_IDS (or `busybox --error-ids APPLET`) the id is the
#      only thing added to stdout, the message keeps the id in front of it, and
#      with the switch off the output is byte-identical to before.
set -u
BB="${1:?usage: streams.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[ -x "$BB" ] || { echo "not executable: $BB" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1

pass=0 fail=0
ck() { # ck <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL %-56s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}
sec() { printf '== %s ==\n' "$1"; }
cnt() { tr -d " " ; }

# run <args...>; sets rc/out/err as file paths
run() {
	"$BB" "$@" </dev/null >"$T/o" 2>"$T/e"
	rc=$?
}
# stdout as one escaped line
ol() { tr '\n' '|' < "$T/o"; }
el() { tr '\n' '|' < "$T/e"; }

sec "1. a diagnostic goes to stderr for every applet that rejects an argument"

# Applets whose stdout is shell code or data by design, and interpreters that
# would block or run something: not part of the sweep.
# Also skipped: applets that ignore an unknown argument and produce data or
# write forever (`yes` produced 650 MB before its timeout), so they cannot be
# swept this way.
skip=" resize yes nologin [ [[ ash hush sh vi ed sed awk less more telnet nc su
 login httpd crond inetd telnetd ftpd udhcpd udhcpc syslogd klogd watchdog getty
 chat adduser deluser passwd chpasswd "

swept=0
bad=0
for a in $("$BB" --list); do
	case "$skip" in
	*" $a "*) continue ;;
	esac
	# Bounded to a file: an applet that ignores the argument can write a lot
	# (or forever) before its timeout, and a shell variable would hold it all.
	timeout 2 "$BB" "$a" --nrs-bad-option-xyz </dev/null >"$T/so" 2>/dev/null
	rc=$?
	swept=$((swept + 1))
	if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] && [ -s "$T/so" ]; then
		bad=$((bad + 1))
		printf '  stdout on rejection: %s (rc=%s): %s\n' "$a" "$rc" \
			"$("$BB" head -1 "$T/so" | cut -c1-60)"
	fi
	rm -f "$T/so"
done
ck "no applet writes a diagnostic to stdout ($swept applets swept)" "0" "$bad"

sec "2. with the switch off, nothing changes"

run cat /nope
ck "default: exit status" "1" "$rc"
ck "default: stdout is empty" "" "$(ol)"
ck "default: message on stderr" "1" "$(grep -c "cat: can't open '/nope'" "$T/e")"
ck "default: no id in the message" "0" "$(grep -c 'NOT_FOUND' "$T/e")"

BUSYBOX_ERROR_IDS=0 "$BB" cat /nope >"$T/o" 2>"$T/e"
ck "BUSYBOX_ERROR_IDS=0 is off" "" "$(ol)"

sec "3. with the switch on, the id is on stdout and the message keeps it"

BUSYBOX_ERROR_IDS=1 "$BB" cat /nope >"$T/o" 2>"$T/e"
ck "env: exit status unchanged" "1" "$?"
ck "env: stdout is the id alone" "E NOT_FOUND|" "$(ol)"
ck "env: stderr has the id in front" "1" "$(grep -c "cat: NOT_FOUND: can't open '/nope'" "$T/e")"

"$BB" --error-ids cat /nope >"$T/o" 2>"$T/e"
ck "flag: stdout is the id alone" "E NOT_FOUND|" "$(ol)"
ck "flag: stderr has the id in front" "1" "$(grep -c "cat: NOT_FOUND:" "$T/e")"

"$BB" --error-ids cat /nope >"$T/o" 2>"$T/message"
ck "flag: the message is not on stdout" "0" "$(grep -c "can't open" "$T/o")"

run --error-ids echo hi
ck "success adds no id" "hi|" "$(ol)"
ck "success leaves stderr empty" "" "$(el)"

sec "4. the id is the reason, not the text"

run --error-ids cat /etc
ck "EISDIR -> IS_DIR" "E IS_DIR|" "$(ol)"

run --error-ids kill 999999
ck "ESRCH -> NOT_FOUND" "E NOT_FOUND|" "$(ol)"

printf 'x\n' > secret.txt
chmod 000 secret.txt
run --error-ids cat secret.txt
if [ "$rc" -ne 0 ]; then
	ck "EACCES -> PERMISSION" "E PERMISSION|" "$(ol)"
else
	ck "EACCES -> PERMISSION (root? skipped)" "1" "1"
fi
chmod 644 secret.txt

run --error-ids chmod 644 /nope/x
ck "a path's missing parent is NOT_FOUND" "E NOT_FOUND|" "$(ol)"

sec "5. a usage error is one id, and the usage text stays on stderr"

run --error-ids ls --nrs-bad-option
ck "usage: one id on stdout" "1" "$(wc -l < "$T/o" | cnt)"
ck "usage: the id is E USAGE" "E USAGE|" "$(ol)"
ck "usage: the usage text is on stderr" "1" "$(grep -c 'Usage:' "$T/e")"
ck "usage: exit status is the usage status" "1" "$([ "$rc" -ne 0 ] && echo 1)"

run --error-ids
ck "--error-ids without an applet fails" "1" "$([ "$rc" -ne 0 ] && echo 1)"

sec "6. a warning keeps its own channel"

printf 'one two\n' > w.txt
run --error-ids od --width=0 w.txt
ck "warning: W channel is the first stdout line" "W WARN" "$("$BB" head -1 "$T/o")"
ck "warning: id in front of the message" "1" "$(grep -c 'od: WARN: warning: invalid width' "$T/e")"

sec "7. machine-readable applets keep their code in the object, not in a second id"

run --error-ids peek /nope --format json
ck "json error still goes to stdout" "1" "$(grep -c '"code":"NOT_FOUND"' "$T/o")"
ck "json error adds no id line" "0" "$(grep -c '^E ' "$T/o")"
ck "json error says nothing on stderr" "" "$(el)"

sec "8. run --error-ids separates the streams and names the codes"

run run --error-ids -- "$BB" cat /nope
ck "run: the view shows the id on stdout" "1" "$(grep -c '^E NOT_FOUND$' "$T/o")"
ck "run: the message with the id is on stderr" "1" "$(grep -c "NOT_FOUND: can't open '/nope'" "$T/o")"
ck "run: exit status is the child's" "1" "$rc"

run run --error-ids -F json -- sh -c "$BB cat /nope; $BB cat /etc"
ck "run json: codes names both" "1" "$("$BB" grep -c '"codes":\["E NOT_FOUND","E IS_DIR"\]' "$T/o")"
ck "run json: codes is one line" "1" "$(wc -l < "$T/o" | cnt)"

run run -F json -- "$BB" cat /nope
ck "run without the flag has no codes key" "0" "$("$BB" grep -c '"codes"' "$T/o")"
ck "run without the flag: no id anywhere" "0" \
	"$("$BB" grep -c 'NOT_FOUND' "$T/o" "$T/e" | "$BB" awk -F: '{s+=$2} END{print s+0}')"
ck "run without the flag: the plain message survives" "1" \
	"$("$BB" grep -c "can't open '/nope'" "$T/o" "$T/e" | "$BB" awk -F: '{s+=$2} END{print (s>0)?1:0}')"

sec "9. ids are opt-in per invocation, not sticky"

run --error-ids cat /nope
run cat /nope
ck "the next invocation is back to normal" "" "$(ol)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
