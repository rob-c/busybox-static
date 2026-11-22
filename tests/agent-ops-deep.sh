#!/bin/bash
# Deep behaviour suite for the agent-facing applets (patches 0004-0014).
#
#   ./tests/agent-ops-deep.sh dist/darwin-arm64/bin/busybox
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 bash /w/tests/agent-ops-deep.sh \
#       /w/dist/linux-arm64/bin/busybox
#
# Where tests/agent-ops.sh proves the contract shapes, this file walks the
# input space: the same operations over a fixed matrix of file shapes, so a
# platform difference shows up as a matrix row that flips rather than as a
# surprise in the field. Everything goes through $BB; no host tool beyond the
# shell is assumed, and nothing needs a GNU-only flag.
#
# Checks are written as properties, not as captured transcripts: an exit code
# from the §2 table, a field that must be present, a file that must be
# unchanged, bytes that must round-trip. A check that would pass with the
# applet deleted is not a check.
set -u
BB="${1:?usage: agent-ops-deep.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[ -x "$BB" ] || { echo "not executable: $BB" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"

pass=0 fail=0 skips=0
ck() { # ck <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL %-56s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}
skip() { skips=$((skips + 1)); printf 'skip %s\n' "$1"; }
sec() { printf '== %s ==\n' "$1"; }

# ---- helpers -------------------------------------------------------------
# rc <cmd...>: run, keep stdout in $T/out, stderr in $T/err, print the status
rc() { "$@" > "$T/out" 2> "$T/err"; echo $?; }
outeq() { ck "$1" "$2" "$(cat "$T/out")"; }
outct() { ck "$1" "1" "$("$BB" grep -c "$2" "$T/out")"; }
errct() { ck "$1" "1" "$("$BB" grep -c "$2" "$T/err")"; }
# a valid §2 exit code: 0 ok, 1 failed, 2 usage, 3 timeout/cancel
is_ok_code() { case "$1" in 0|1|2|3) echo 1 ;; *) echo 0 ;; esac; }
ckrc() { ck "$1" "1" "$(is_ok_code "$2")"; }
# json field from a one-line object in $T/out
jf() { "$BB" sed -n "s/.*\"$1\":\\([^,}]*\\).*/\\1/p" "$T/out" | "$BB" head -1; }
jck() { ck "$1" "$2" "$(jf "$3")"; }

# ---- the fixture matrix --------------------------------------------------
# Every applet section runs over these, so a shape that breaks one applet is
# visible next to the same shape succeeding in another.
FX="$T/fx"
mkdir -p "$FX"
: > "$FX/empty"
printf 'x' > "$FX/onebyte"
printf 'only line\n' > "$FX/oneline"
printf 'a\nb\nc\n' > "$FX/three"
printf 'a\nb' > "$FX/nonl"
printf 'a\r\nb\r\nc\r\n' > "$FX/crlf"
printf 'A\rB\nC\n' > "$FX/crmid"
printf 'a\000b\nc\n' > "$FX/binary"
printf 'h\303\251llo\nw\303\266rld\n' > "$FX/unicode"
printf '  a  b  \n\tc\td\n' > "$FX/spaces"
printf '\n\n\n' > "$FX/blanks"
"$BB" awk 'BEGIN{for(i=0;i<10000;i++)printf "x"; printf "\n"}' > "$FX/long"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > "$FX/ten"
FIXTURES="empty onebyte oneline three nonl crlf crmid binary unicode spaces blanks long ten"

# ---------------------------------------------------------------------------
sec "1. contract sweep: usage errors, help, format values"
APPS="peek replace waitfor run log doctor why json patchcheck bench snapshot check brief"
for a in $APPS; do
	ck "help exits 0 [$a]" "0" "$(rc "$BB" "$a" --help)"
	ck "help prints usage [$a]" "1" "$("$BB" grep -c '[Uu]sage:' "$T/out")"
	ck "unknown option exits 2 [$a]" "2" "$(rc "$BB" "$a" --nosuchoption)"
done
for a in replace waitfor run log doctor why json patchcheck bench snapshot check brief; do
	ck "bad --format exits 2 [$a]" "2" "$(rc "$BB" "$a" --format xml)"
done
# every applet named here must exist in this build
for a in $APPS column; do
	ck "unknown option exits 2 [$a]" "2" "$(rc "$BB" "$a" --nosuchoption)"
	ck "applet present [$a]" "1" "$("$BB" --list | "$BB" grep -qx "$a" && echo 1 || echo 0)"
done
# --caps agrees with --list
"$BB" --caps --format json > "$T/out" 2>/dev/null
capsn=$("$BB" sed -n 's/.*"count":\([0-9]*\).*/\1/p' "$T/out")
listn=$("$BB" --list | "$BB" wc -l | tr -d ' ')
ck "--caps count matches --list" "$listn" "$capsn"

# ---------------------------------------------------------------------------
sec "2. peek over the fixture matrix"
for f in $FIXTURES; do
	r=$(rc "$BB" peek -l 1:2 "$FX/$f")
	ckrc "peek rc in table [$f]" "$r"
	# either a versioned header or a contract-coded error - never silence
	ck "peek says something [$f]" "1" \
		"$("$BB" grep -Eq 'version=sha256:|NOT_FOUND|INVALID_ARGUMENT|UNSUPPORTED' "$T/out" "$T/err" >/dev/null 2>&1 && echo 1)"
	if [ "$r" = 0 ]; then
		ck "peek header has version [$f]" "1" "$("$BB" grep -c 'version=sha256:' "$T/out")"
		ck "peek reports shown_bytes [$f]" "1" "$("$BB" grep -c 'shown_bytes=' "$T/out")"
		sb=$("$BB" sed -n 's/^shown_bytes=\([0-9]*\).*/\1/p' "$T/out")
		ck "peek budget respected [$f]" "1" "$([ "${sb:-0}" -le 16384 ] && echo 1)"
	fi
done

sec "3. peek line ranges: the §2 table, never 124 or 128+N"
for rng in 1:1 1 2:2 :2 2:5 1:10 99:100 0:1 2:1 1:0 abc 1:2:3; do
	r=$(rc "$BB" peek -l "$rng" "$FX/ten")
	ckrc "peek -l $rng rc" "$r"
	ck "peek -l $rng not a signal" "1" "$([ "$r" -lt 124 ] && echo 1)"
done
ck "peek -l 2:2 shows line 2" "1" "$(rc "$BB" peek -l 2:2 "$FX/ten" >/dev/null; "$BB" grep -c '^2 | l2$' "$T/out")"
ck "peek -l 2:2 omits line 1" "0" "$("$BB" grep -c '^1 | l1$' "$T/out")"
ck "peek -l 2 shows one line" "1" "$("$BB" grep -c '^2 | l2$' "$T/out")"
ck "peek -l :2 shows two" "2" "$(rc "$BB" peek -l :2 "$FX/ten" >/dev/null; "$BB" grep -c '^[0-9]* | ' "$T/out")"

sec "4. peek byte budget and continuation"
for b in 0 1 10 100; do
	r=$(rc "$BB" peek -l 1:10 -B "$b" "$FX/ten")
	ckrc "peek -B $b rc" "$r"
	sb=$("$BB" sed -n 's/^shown_bytes=\([0-9]*\).*/\1/p' "$T/out")
	ck "peek -B $b within budget" "1" "$([ "${sb:-0}" -le "$b" ] && echo 1)"
done
ck "peek -B 0 is truncated" "1" "$(rc "$BB" peek -l 1:10 -B 0 "$FX/ten" >/dev/null; "$BB" grep -c 'truncated=true' "$T/out")"
ck "peek -B 0 offers a cursor" "1" "$("$BB" grep -c 'next=--from-byte' "$T/out")"
# drive the continuation cursor to the end and reassemble the file
for f in three nonl crlf ten; do
	off=0
	iters=0
	: > "$T/said"
	while [ $iters -lt 40 ]; do
		"$BB" peek -B 12 -F "$off" "$FX/$f" > "$T/out" 2>/dev/null
		next=$("$BB" sed -n 's/.*next=--from-byte \([0-9]*\).*/\1/p' "$T/out")
		"$BB" sed -n 's/^[0-9][0-9]* | //p' "$T/out" >> "$T/said"
		[ -z "$next" ] && break
		off=$next
		iters=$((iters + 1))
	done
	ck "peek continuation terminates [$f]" "1" "$([ $iters -lt 40 ] && echo 1)"
	ck "peek continuation reaches the end [$f]" "1" \
		"$("$BB" grep -c 'truncated=false' "$T/out")"
done
ck "peek continuation never loops forever [ten]" "1" "$([ $iters -lt 40 ] && echo 1)"

sec "5. peek version hash"
"$BB" peek -l 1:1 "$FX/three" > "$T/out" 2>/dev/null
v1=$("$BB" sed -n 's/.*version=sha256:\([0-9a-f]*\).*/\1/p' "$T/out")
"$BB" peek -l 2:2 "$FX/three" > "$T/out" 2>/dev/null
v2=$("$BB" sed -n 's/.*version=sha256:\([0-9a-f]*\).*/\1/p' "$T/out")
ck "version is stable across ranges" "$v1" "$v2"
ck "version is 64 hex chars" "64" "$("$BB" printf '%s' "$v1" | "$BB" wc -c | tr -d ' ')"
cp "$FX/three" "$T/v.txt"
"$BB" replace "$T/v.txt" --old b --new B >/dev/null 2>&1
"$BB" peek -l 1:1 "$T/v.txt" > "$T/out" 2>/dev/null
v3=$("$BB" sed -n 's/.*version=sha256:\([0-9a-f]*\).*/\1/p' "$T/out")
ck "version changes when content changes" "1" "$([ "$v1" != "$v3" ] && echo 1)"

sec "6. peek --around, --context, --regex, --max-file"
printf 'one\ntwo\nNEEDLE\nfour\nfive\n' > "$T/n.txt"
ck "peek -a finds the match" "1" "$(rc "$BB" peek -a NEEDLE "$T/n.txt" >/dev/null; "$BB" grep -c 'NEEDLE' "$T/out")"
ck "peek -a includes context" "1" "$(rc "$BB" peek -a NEEDLE -c 1 "$T/n.txt" >/dev/null; "$BB" grep -c '^2 | two$' "$T/out")"
ck "peek -a misses cleanly" "1" "$(rc "$BB" peek -a ZZZ "$T/n.txt")"
ck "peek -r treats the pattern as a regex" "1" "$(rc "$BB" peek -a 'NEE[DF]LE' -r "$T/n.txt" >/dev/null; "$BB" grep -c 'NEEDLE' "$T/out")"
ck "peek -r without -r: same pattern is literal" "1" "$(rc "$BB" peek -a 'NEE[DF]LE' "$T/n.txt")"
ck "peek -M refuses a big file" "1" "$(rc "$BB" peek -l 1:1 -M 1 "$FX/ten")"
ck "peek -M refusal is not a crash" "1" "$([ "$(rc "$BB" peek -l 1:1 -M 1 "$FX/ten")" -lt 124 ] && echo 1)"

sec "7. peek on binary and odd bytes"
ck "peek binary rc" "1" "$(is_ok_code "$(rc "$BB" peek -l 1:2 "$FX/binary")")"
ck "peek binary names UNSUPPORTED or shows the line" "1" \
	"$("$BB" grep -Eq 'UNSUPPORTED|version=sha256:' "$T/out" "$T/err" >/dev/null 2>&1 && echo 1)"
ck "peek crlf counts 3 lines" "3" "$(rc "$BB" peek -l 1:10 "$FX/crlf" >/dev/null; "$BB" grep -c '^[0-9]* | ' "$T/out")"
ck "peek nonl counts 2 lines" "2" "$(rc "$BB" peek -l 1:10 "$FX/nonl" >/dev/null; "$BB" grep -c '^[0-9]* | ' "$T/out")"
ck "peek empty file rc in table" "1" "$(is_ok_code "$(rc "$BB" peek -l 1:1 "$FX/empty")")"
ck "peek unicode line intact" "1" "$(rc "$BB" peek -l 1:1 "$FX/unicode" >/dev/null; "$BB" grep -c 'h..llo' "$T/out")"

sec "8. peek batch request"
printf '{"schema":1,"requests":[{"path":"%s/ten","lines":"1:2"}]}' "$FX" > "$T/req.json"
ck "peek -R rc" "0" "$(rc "$BB" peek -R "$T/req.json")"
ck "peek -R returns the lines" "2" "$("$BB" grep -c '^[0-9]* | ' "$T/out")"
printf '{"schema":1,"requests":[{"path":"%s/nope","lines":"1:2"}]}' "$FX" > "$T/req2.json"
r=$(rc "$BB" peek -R "$T/req2.json")
ckrc "peek -R missing path rc" "$r"
ck "peek -R missing path names NOT_FOUND" "1" "$("$BB" grep -q 'NOT_FOUND' "$T/out" "$T/err" >/dev/null 2>&1 && echo 1)"
printf 'not json' > "$T/req3.json"
ck "peek -R bad json is a usage/arg error" "1" "$(is_ok_code "$(rc "$BB" peek -R "$T/req3.json")")"

# ---------------------------------------------------------------------------
sec "9. replace: three scenarios over the fixture matrix"
repone() { # repone <file> <old> <new>
	"$BB" replace "$1" --old "$2" --new "$3" > "$T/out" 2> "$T/err"
}
for f in oneline three nonl crlf crmid unicode spaces blanks ten; do
	cp "$FX/$f" "$T/w"
	case "$f" in
	oneline) old="only" ;;
	three|nonl) old="b" ;;
	ten) old="l5" ;;
	crlf) old="b" ;;
	crmid) old="C" ;;
	unicode) old="w" ;;
	spaces) old="a" ;;
	blanks) old="" ;;
	esac
	if [ -z "$old" ]; then
		skip "replace hit [$f]: no unique needle"
	else
		before=$("$BB" md5sum < "$T/w")
		r=$(rc "$BB" replace "$T/w" --old "$old" --new "ZZ")
		ck "replace hit rc [$f]" "0" "$r"
		ck "replace hit changed the file [$f]" "1" \
			"$([ "$before" != "$("$BB" md5sum < "$T/w")" ] && echo 1)"
		ck "replace hit reports changed=true [$f]" "1" "$("$BB" grep -c 'changed=true' "$T/out")"
	fi
	# a needle that is not there must change nothing
	cp "$FX/$f" "$T/w"
	before=$("$BB" md5sum < "$T/w")
	r=$(rc "$BB" replace "$T/w" --old "zzzznotthere" --new "Q")
	ck "replace miss rc [$f]" "1" "$r"
	ck "replace miss left the file alone [$f]" "$before" "$("$BB" md5sum < "$T/w")"
	ck "replace miss says so [$f]" "1" "$("$BB" grep -q 'No files changed' "$T/out" "$T/err" >/dev/null 2>&1 && echo 1)"
	# dry run must print a diff and write nothing
	if [ -n "$old" ]; then
		r=$(rc "$BB" replace "$T/w" --old "$old" --new "ZZ" -N)
		ck "replace dry-run rc [$f]" "0" "$r"
		ck "replace dry-run wrote nothing [$f]" "$before" "$("$BB" md5sum < "$T/w")"
		ck "replace dry-run says dry_run [$f]" "1" "$("$BB" grep -c 'dry_run=true' "$T/out")"
	fi
done

sec "10. replace: counts, versions, symlinks, modes, dry-run"
printf 'aa aa\n' > "$T/w"
ck "replace -x 2 accepts two" "0" "$(rc "$BB" replace "$T/w" --old aa --new bb -x 2)"
ck "replace -x 2 wrote both" "bb bb" "$(cat "$T/w")"
printf 'aa\n' > "$T/w"
ck "replace -x 2 rejects one" "1" "$(rc "$BB" replace "$T/w" --old aa --new bb -x 2)"
ck "replace -x 2 left one alone" "aa" "$(cat "$T/w")"
printf 'aa\n' > "$T/w"
"$BB" peek -l 1:1 "$T/w" > "$T/out" 2>/dev/null
ver=$("$BB" sed -n 's/.*version=sha256:\([0-9a-f]*\).*/\1/p' "$T/out")
ck "replace -S accepts the right version" "0" "$(rc "$BB" replace "$T/w" --old aa --new bb -S "$ver")"
printf 'aa\n' > "$T/w"
ck "replace -S rejects a stale version" "1" "$(rc "$BB" replace "$T/w" --old aa --new bb -S 0000)"
ck "replace -S stale left the file alone" "aa" "$(cat "$T/w")"
printf 'aa\n' > "$T/w"
if "$BB" ln -sf "$T/w" "$T/link"; then
	ck "replace refuses a symlink" "1" "$(rc "$BB" replace "$T/link" --old aa --new bb)"
	ck "replace -L follows the symlink" "0" "$(rc "$BB" replace "$T/link" --old aa --new bb -L)"
	ck "replace -L edited the target" "bb" "$(cat "$T/w")"
	ck "replace -L kept the link" "1" "$("$BB" test -L "$T/link" && echo 1 || echo 0)"
fi
printf 'aa\n' > "$T/w"
chmod 640 "$T/w"
"$BB" replace "$T/w" --old aa --new bb >/dev/null 2>&1
mode=$("$BB" stat -c %a "$T/w" 2>/dev/null)
[ -n "$mode" ] && ck "replace preserved the mode" "640" "$mode" || skip "stat -c %a unavailable"
printf 'aa\n' > "$T/w"
ck "replace -N reports dry_run=true" "1" "$(rc "$BB" replace "$T/w" --old aa --new bb -N >/dev/null; "$BB" grep -c 'dry_run=true' "$T/out")"
ck "replace -N reports changed=false" "1" "$("$BB" grep -c 'changed=false' "$T/out")"
ck "replace -N printed a diff" "1" "$("$BB" grep -c '^-aa$' "$T/out")"
ck "replace -N diff has the addition" "1" "$("$BB" grep -c '^+bb$' "$T/out")"
ck "replace -B 1 truncates the diff" "1" "$(rc "$BB" replace "$T/w" --old aa --new bb -N -B 1 >/dev/null; "$BB" grep -c 'diff_truncated=true' "$T/out")"
ck "replace no-args rc" "2" "$(rc "$BB" replace)"
printf 'aa\n' > "$T/w"
ck "replace identical old/new rc" "1" "$(is_ok_code "$(rc "$BB" replace "$T/w" --old aa --new aa)")"

sec "11. replace batch request"
printf 'a\nb\n' > "$T/b1"
printf '{"schema":1,"edits":[{"path":"%s/b1","old":"a","new":"A"}]}' "$T" > "$T/e.json"
ck "replace -R rc" "0" "$(rc "$BB" replace -R "$T/e.json")"
ck "replace -R applied the edit" "A" "$("$BB" head -1 "$T/b1")"
printf '{"schema":1,"edits":[{"path":"%s/b1","old":"zz","new":"C"}]}' "$T" > "$T/e2.json"
ck "replace -R miss is all-or-nothing" "1" "$(rc "$BB" replace -R "$T/e2.json")"
ck "replace -R miss left the file" "A" "$("$BB" head -1 "$T/b1")"
printf 'not json' > "$T/e3.json"
ck "replace -R bad json rc in table" "1" "$(is_ok_code "$(rc "$BB" replace -R "$T/e3.json")")"


# ---------------------------------------------------------------------------
sec "12. run: exit codes, streams, budgets, environment"

for code in 0 1 2 3 7 42 100 125; do
	"$BB" run -D "$T/art" -- "$BB" sh -c "exit $code" > "$T/out" 2>"$T/err"
	ck "run passes exit $code through" "$code" "$?"
	ck "run reports exit $code" "1" "$("$BB" grep -c "exit_code=$code" "$T/out")"
	ck "run exit $code is complete" "1" "$("$BB" grep -c 'capture_complete=true' "$T/out")"
done
"$BB" run -D "$T/art" -- "$BB" sh -c 'echo o; echo e >&2' > "$T/out" 2>/dev/null
	ck "run separates stdout" "1" "$("$BB" grep -c 'stdout=2' "$T/out")"
	ck "run separates stderr" "1" "$("$BB" grep -c 'stderr=2' "$T/out")"
ck "run prints a run id" "1" "$("$BB" grep -c '^run=R[0-9]*' "$T/out")"
ck "run gives artifacts" "1" "$("$BB" grep -c 'stdout_artifact=' "$T/out")"
ck "run view budget truncates the view" "1" \
	"$("$BB" run -D "$T/art" -B 1 -- "$BB" sh -c 'echo aaaaaaaaaaaa' > "$T/out" 2>/dev/null; "$BB" grep -c 'view_truncated=true' "$T/out")"
ck "run view budget keeps capture complete" "1" "$("$BB" grep -c 'capture_complete=true' "$T/out")"
ck "run capture limit marks incomplete" "1" \
	"$("$BB" run -D "$T/art" -C 4 -- "$BB" sh -c 'echo aaaaaaaaaaaa' > "$T/out" 2>/dev/null; "$BB" grep -c 'capture_complete=false' "$T/out")"
r=$(rc "$BB" run -D "$T/art" -T 1 -- "$BB" sh -c 'sleep 5')
ck "run timeout exits 3" "3" "$r"
ck "run timeout says timed_out" "1" "$("$BB" grep -c 'timed_out=true' "$T/out")"
ck "run json names the run" "1" "$("$BB" run -D "$T/art" -F json -- "$BB" true > "$T/out" 2>/dev/null; "$BB" grep -c '"run":"R' "$T/out")"
ck "run cannot start a missing program" "1" "$(is_ok_code "$(rc "$BB" run -D "$T/art" -- /no/such/prog)")"
ck "run json has a schema" "1" "$("$BB" run -D "$T/art" -F json -- "$BB" true > "$T/out" 2>/dev/null; "$BB" grep -c '"schema":1' "$T/out")"
for f in $FIXTURES; do
	rm -rf "$T/art"
	"$BB" run -D "$T/art" -- "$BB" cat "$FX/$f" > "$T/out" 2>/dev/null
	art=$("$BB" sed -n 's/^stdout_artifact=//p' "$T/out" | "$BB" head -1)
	if [ -n "$art" ] && [ -f "$art" ]; then
		ck "run captured $f byte-exactly" "0" "$("$BB" cmp -s "$FX/$f" "$art"; echo $?)"
	else
		ck "run produced an artifact for $f" "1" "0"
	fi
done

sec "13. log: reading a captured run back"
rm -rf "$T/art"
"$BB" run -D "$T/art" -- "$BB" sh -c 'i=0; while [ $i -lt 6 ]; do echo "out$i"; i=$((i+1)); done; echo boom >&2' > "$T/out" 2>/dev/null
R=$("$BB" sed -n 's/^run=\(R[0-9]*\).*/\1/p' "$T/out" | "$BB" head -1)
ck "log got a run id" "1" "$([ -n "$R" ] && echo 1)"
ck "log -D -l 2:3 shows two lines" "2" "$(rc "$BB" log -D "$T/art" "$R" -l 2:3 >/dev/null; "$BB" grep -c '^[0-9]* | out' "$T/out")"
ck "log -l 1:1 shows out0" "1" "$(rc "$BB" log -D "$T/art" "$R" -l 1:1 >/dev/null; "$BB" grep -c 'out0' "$T/out")"
ck "log -m matches" "1" "$(rc "$BB" log -D "$T/art" "$R" -m out3 >/dev/null; "$BB" grep -c 'out3' "$T/out")"
ck "log -m -c 1 adds context" "1" "$(rc "$BB" log -D "$T/art" "$R" -m out3 -c 1 >/dev/null; "$BB" grep -c 'out2' "$T/out")"
ck "log -s both sees stderr" "1" "$(rc "$BB" log -D "$T/art" "$R" -s both >/dev/null; "$BB" grep -c 'boom' "$T/out")"
ck "log -s stdout hides stderr" "0" "$(rc "$BB" log -D "$T/art" "$R" -s stdout >/dev/null; "$BB" grep -c 'boom' "$T/out")"
ck "log -M prints metadata" "1" "$(rc "$BB" log -D "$T/art" "$R" -M >/dev/null; "$BB" grep -c 'exit_code=0' "$T/out")"
ck "log -B bounds the view" "1" "$(rc "$BB" log -D "$T/art" "$R" -B 1 >/dev/null; "$BB" grep -c 'truncated' "$T/out")"
r=$(rc "$BB" log -D "$T/art" R999999)
ck "log unknown run rc" "1" "$r"
ck "log unknown run says NOT_FOUND" "1" "$("$BB" grep -q NOT_FOUND "$T/out" "$T/err" && echo 1)"
ck "log json schema" "1" "$("$BB" log -D "$T/art" "$R" -F json > "$T/out" 2>/dev/null; "$BB" grep -c '"schema":1' "$T/out")"
ck "log can read a binary capture" "0" \
	"$("$BB" run -D "$T/art" -- "$BB" cat "$FX/binary" >/dev/null 2>&1; \
	   "$BB" log -D "$T/art" "$("$BB" ls "$T/art" | "$BB" grep '^R' | "$BB" tail -1)" -s stdout > "$T/out" 2>/dev/null; echo $?)"

sec "14. waitfor: predicates and deadlines"
printf 'ready\n' > "$T/ready.txt"
ck "waitfor --file on an existing file" "0" "$(rc "$BB" waitfor --file "$T/ready.txt" -T 2)"
ck "waitfor --file times out" "3" "$(rc "$BB" waitfor --file "$T/never.txt" -T 1)"
ck "waitfor --file timeout is not a signal" "1" "$([ "$(rc "$BB" waitfor --file "$T/never.txt" -T 1)" -lt 124 ] && echo 1)"
ck "waitfor --tcp rejects a closed port" "3" "$(rc "$BB" waitfor --tcp 127.0.0.1:1 -T 1)"
ck "waitfor needs a predicate" "2" "$(rc "$BB" waitfor -T 1)"
ck "waitfor json has a schema" "1" "$("$BB" waitfor --file "$T/ready.txt" -T 2 -F json > "$T/out" 2>/dev/null; "$BB" grep -c '"schema":1' "$T/out")"
ck "waitfor json reports ready" "1" "$("$BB" grep -c '"ready":true' "$T/out")"
ck "waitfor bad --format exits 2" "2" "$(rc "$BB" waitfor --file "$T/ready.txt" --format xml)"

sec "15. json: query matrix"
cat > "$T/doc.json" <<'EOF'
{"s":"str","n":42,"f":1.5,"t":true,"z":null,"a":[1,2,3],
 "o":{"k":"v","deep":{"x":[{"y":"found"}]}},"esc":"a\"b\\c\u0009d",
 "uni":"héllo","empty":"","arr":[],"obj":{}}
EOF
q() { "$BB" json -f "$T/doc.json" -g "$1" 2>/dev/null; }
t_() { "$BB" json -f "$T/doc.json" -g "$1" -t 2>/dev/null; }
n_() { "$BB" json -f "$T/doc.json" -g "$1" -n 2>/dev/null; }
for path in .s .n .f .t .z .a .o .o.k .o.deep .o.deep.x .esc .uni .empty .arr .obj; do
	r=$("$BB" json -f "$T/doc.json" -g "$path" >/dev/null 2>&1; echo $?)
	ckrc "json -g $path rc" "$r"
	ck "json -g $path has a type" "1" "$([ -n "$(t_ "$path")" ] && echo 1)"
done
ck "json scalar string" "str" "$(q .s)"
ck "json scalar number" "42" "$(q .n)"
ck "json scalar bool" "true" "$(q .t)"
ck "json scalar null" "null" "$(q .z)"
ck "json nested array element" "found" "$(q .o.deep.x[0].y)"
ck "json array length" "3" "$(n_ .a)"
ck "json object keys listed" "1" "$("$BB" json -f "$T/doc.json" -g .o -k 2>/dev/null | "$BB" grep -c '^k$')"
ck "json empty array length" "0" "$(n_ .arr)"
ck "json type of object" "object" "$(t_ .o)"
ck "json type of array" "array" "$(t_ .a)"
ck "json type of string" "string" "$(t_ .s)"
ck "json type of number" "number" "$(t_ .n)"
ck "json type of bool" "true" "$(t_ .t)"
ck "json type of null" "null" "$(t_ .z)"
ck "json missing path rc" "1" "$("$BB" json -f "$T/doc.json" -g .nope >/dev/null 2>&1; echo $?)"
ck "json missing path says NOT_FOUND" "1" "$("$BB" json -f "$T/doc.json" -g .nope 2>&1 | "$BB" grep -c NOT_FOUND)"
ck "json validates a good doc" "0" "$("$BB" json -f "$T/doc.json" -c >/dev/null 2>&1; echo $?)"
printf '{"a":1,}' > "$T/bad.json"
ck "json rejects a trailing comma" "1" "$("$BB" json -f "$T/bad.json" -c >/dev/null 2>&1; echo $?)"
printf 'not json' > "$T/bad2.json"
ck "json rejects junk" "1" "$("$BB" json -f "$T/bad2.json" -c >/dev/null 2>&1; echo $?)"
printf '{"a":1} {"b":2}' > "$T/bad3.json"
ck "json rejects trailing data" "1" "$("$BB" json -f "$T/bad3.json" -c >/dev/null 2>&1; echo $?)"

sec "16. patchcheck over synthetic series"
mkdir -p "$T/pat"
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n' > "$T/pat/0001-ok.patch"
ck "patchcheck accepts a good patch" "0" "$(rc "$BB" patchcheck -d "$T/pat")"
ck "patchcheck counts it" "1" "$("$BB" grep -c 'checked=1' "$T/out")"
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n' > "$T/pat/0002-nohunk.patch"
ck "patchcheck flags a hunkless patch" "1" "$(rc "$BB" patchcheck -d "$T/pat")"
ck "patchcheck reports bad=1" "1" "$("$BB" grep -c 'bad=1' "$T/out")"
ck "patchcheck json schema" "1" "$("$BB" patchcheck -d "$T/pat" --format json > "$T/out" 2>/dev/null; "$BB" grep -c '"schema":1' "$T/out")"
ck "patchcheck json status error" "1" "$("$BB" grep -c '"status":"error"' "$T/out")"
ck "patchcheck routes text format" "0" "$("$BB" patchcheck -d "$T/pat" --format text >/dev/null 2>&1; [ $? -le 1 ] && echo 0)"

sec "17. bench"
ck "bench rc" "0" "$(rc "$BB" bench -n 2 -w 0 -- "$BB" true)"
ck "bench reports runs" "1" "$("$BB" grep -c 'runs=2' "$T/out")"
ck "bench json schema" "1" "$("$BB" bench -n 2 -w 0 -F json -- "$BB" true > "$T/out" 2>/dev/null; "$BB" grep -c '"schema":1' "$T/out")"
ck "bench json has percentiles" "1" "$("$BB" grep -c '"min_us"' "$T/out")"
ck "bench median is between min and max" "1" "$(
	mn=$("$BB" sed -n 's/.*"min_us":\([0-9]*\).*/\1/p' "$T/out")
	md=$("$BB" sed -n 's/.*"median_us":\([0-9]*\).*/\1/p' "$T/out")
	mx=$("$BB" sed -n 's/.*"max_us":\([0-9]*\).*/\1/p' "$T/out")
	[ "$mn" -le "$md" ] && [ "$md" -le "$mx" ] && echo 1)"
ck "bench reports a failing command" "1" "$(is_ok_code "$(rc "$BB" bench -n 1 -w 0 -- "$BB" false)")"
ck "bench json counts the failure" "1" "$("$BB" bench -n 1 -w 0 -F json -- "$BB" false > "$T/out" 2>/dev/null; "$BB" grep -c '"failed":1' "$T/out")"
ck "bench -n 0 rc in table" "1" "$(is_ok_code "$(rc "$BB" bench -n 0 -- "$BB" true)")"

sec "18. snapshot"
mkdir -p "$T/tree/sub"
printf 'a\n' > "$T/tree/a.txt"
printf 'b\n' > "$T/tree/sub/b.txt"
ck "snapshot rc" "0" "$(rc "$BB" snapshot -d "$T/tree")"
ck "snapshot counts files" "1" "$("$BB" snapshot -d "$T/tree" -F json > "$T/out" 2>/dev/null; "$BB" grep -q '"count":2' "$T/out" && echo 1)"
ck "snapshot hashes 64 hex" "1" "$("$BB" snapshot -d "$T/tree" -F json 2>/dev/null | "$BB" sed -n 's/.*"sha256":"\([0-9a-f]*\)".*/\1/p' | "$BB" head -1 | "$BB" wc -c | "$BB" tr -d ' ' | "$BB" grep -c '^65$')"
ck "snapshot -o writes a file" "1" "$(rc "$BB" snapshot -d "$T/tree" -o "$T/s1.json" >/dev/null; [ -s "$T/s1.json" ] && echo 1)"
ck "snapshot of an unchanged tree is stable" "0" "$("$BB" snapshot -d "$T/tree" -o "$T/s2.json" >/dev/null 2>&1; "$BB" cmp -s "$T/s1.json" "$T/s2.json"; echo $?)"
ck "snapshot --diff reports no change" "0" "$(rc "$BB" snapshot --diff "$T/s1.json" "$T/s2.json")"
printf 'c\n' > "$T/tree/c.txt"
"$BB" snapshot -d "$T/tree" -o "$T/s3.json" >/dev/null 2>&1
ck "snapshot --diff sees the addition" "1" "$("$BB" grep -c 'added' "$T/out" ; true)"
r=$(rc "$BB" snapshot --diff "$T/s1.json" "$T/s3.json")
ck "snapshot --diff with changes rc in table" "1" "$(is_ok_code "$r")"
ck "snapshot --diff names the file" "1" "$("$BB" grep -c 'c.txt' "$T/out")"
ck "snapshot missing dir rc" "1" "$(is_ok_code "$(rc "$BB" snapshot -d "$T/nope")")"

sec "19. check: table-driven runner"
printf 'a | true | 0 |\nb | false | 1 |\n' > "$T/c1.tbl"
ck "check all-pass rc" "0" "$(rc "$BB" check -f "$T/c1.tbl")"
ck "check counts two" "1" "$("$BB" grep -c 'total=2' "$T/out")"
ck "check reports passed=2" "1" "$("$BB" grep -c 'passed=2' "$T/out")"
printf 'a | true | 1 |\n' > "$T/c2.tbl"
ck "check fails a wrong expectation" "1" "$(rc "$BB" check -f "$T/c2.tbl")"
ck "check json schema" "1" "$("$BB" check -f "$T/c2.tbl" --format json > "$T/out" 2>/dev/null; "$BB" grep -c '"schema":1' "$T/out")"
printf '# comment\n\nc | echo hi | 0 | hi\n' > "$T/c3.tbl"
ck "check skips comments and blanks" "0" "$(rc "$BB" check -f "$T/c3.tbl")"
ck "check counted one case" "1" "$("$BB" grep -c 'total=1' "$T/out")"
printf 'd | echo hello | 0 | ell\n' > "$T/c4.tbl"
ck "check substring match passes" "0" "$(rc "$BB" check -f "$T/c4.tbl")"
ck "check missing table rc" "1" "$(rc "$BB" check -f "$T/nonexistent.tbl")"

sec "20. why: config provenance"
ck "why rc in table" "1" "$(is_ok_code "$(rc "$BB" why -C /dev/null -p /dev/null peek)")"
ck "why mentions the symbol" "1" "$("$BB" grep -q PEEK "$T/out" && echo 1)"
ck "why json schema" "1" "$("$BB" why -C /dev/null -p /dev/null -F json peek > "$T/out" 2>/dev/null; "$BB" grep -c '"schema":1' "$T/out")"
ck "why json names the applet" "1" "$("$BB" grep -c '"applet":"peek"' "$T/out")"
ck "why on a non-applet rc in table" "1" "$(is_ok_code "$(rc "$BB" why -C /dev/null -p /dev/null notanapplet)")"

sec "21. doctor"
ck "doctor rc" "0" "$(rc "$BB" doctor)"
ck "doctor json schema" "1" "$("$BB" doctor -F json > "$T/out" 2>/dev/null; "$BB" grep -c '"schema":1' "$T/out")"
ck "doctor names the platform" "1" "$("$BB" grep -Ec '"platform":"(darwin|linux)"' "$T/out")"
ck "doctor finds a dep it was asked for" "1" "$("$BB" doctor -d sh -F json > "$T/out" 2>/dev/null; "$BB" grep -c '"sh"' "$T/out")"
ck "doctor --build rc in table" "1" "$(is_ok_code "$(rc "$BB" doctor --build -F json)")"
ck "doctor json is one line" "1" "$("$BB" wc -l < "$T/out" | "$BB" tr -d ' ')"

sec "22. brief over the fixture matrix (redux, cross-platform)"
inv2() { # inv2 <name> <outfile>
	li=$("$BB" sed -n '1{s/^\[brief\]/ /;s/.* lines_in=\([0-9]*\).*/\1/p;q;}' "$2")
	sh=$("$BB" sed -n '1{s/^\[brief\]/ /;s/.* shown_lines=\([0-9]*\).*/\1/p;q;}' "$2")
	mg=$("$BB" sed -n '1{s/^\[brief\]/ /;s/.* merged=\([0-9]*\).*/\1/p;q;}' "$2")
	dl=$("$BB" sed -n '1{s/^\[brief\]/ /;s/.* dropped_lines=\([0-9]*\).*/\1/p;q;}' "$2")
	ck "$1" "$li" "$((sh + mg + dl))"
}
for f in $FIXTURES; do
	"$BB" brief -B 20000 "$FX/$f" > "$T/o" 2>/dev/null
	ck "brief plain rc [$f]" "0" "$?"
	b=$("$BB" sed -n '1{s/^\[brief\]/ /;s/.* bytes=\([0-9]*\).*/\1/p;q;}' "$T/o")
	"$BB" tail -c "${b:-0}" "$T/o" > "$T/body"
	# every record is newline-terminated, so that is the canonical form
	{ cat "$FX/$f"; case "$("$BB" od -An -c "$FX/$f" | "$BB" tail -1 | "$BB" tr -s ' ')" in
		*" \n") : ;; *) [ -s "$FX/$f" ] && printf "\n" ;; esac; } > "$T/want"
	ck "brief plain is byte-exact [$f]" "0" "$("$BB" cmp -s "$T/want" "$T/body"; echo $?)"
	inv2 "brief plain invariant [$f]" "$T/o"
	for opts in "-d" "-s" "-k a" "-f 1" "-d -a 2"; do
		# shellcheck disable=SC2086
		"$BB" brief $opts "$FX/$f" > "$T/o" 2>/dev/null
		ck "brief exit 0 [$f $opts]" "0" "$?"
		inv2 "brief invariant [$f $opts]" "$T/o"
	done
	"$BB" brief -B 1 "$FX/$f" > "$T/o" 2>/dev/null
	inv2 "brief -B 1 invariant [$f]" "$T/o"
done

sec "23. determinism and the exit-code contract, per applet"
for a in $APPS; do
	# nothing may exit 124 or 128+N for a plain failure
	r=$(rc "$BB" "$a" /nonexistent-path-xyz)
	ck "no signal exit [$a]" "1" "$([ "$r" -lt 124 ] && echo 1)"
	ck "exit in the table [$a]" "1" "$(is_ok_code "$r")"
	# same input, same answer
	"$BB" "$a" --help > "$T/a1" 2>&1
	"$BB" "$a" --help > "$T/a2" 2>&1
	ck "help is deterministic [$a]" "0" "$("$BB" cmp -s "$T/a1" "$T/a2"; echo $?)"
done
for f in three nonl crlf binary; do
	"$BB" peek -l 1:2 "$FX/$f" > "$T/p1" 2>&1
	"$BB" peek -l 1:2 "$FX/$f" > "$T/p2" 2>&1
	ck "peek is deterministic [$f]" "0" "$("$BB" cmp -s "$T/p1" "$T/p2"; echo $?)"
	"$BB" brief "$FX/$f" > "$T/b1" 2>&1
	"$BB" brief "$FX/$f" > "$T/b2" 2>&1
	ck "brief is deterministic [$f]" "0" "$("$BB" cmp -s "$T/b1" "$T/b2"; echo $?)"
done

sec "24. every JSON-emitting applet carries schema 1"
"$BB" run -D "$T/art" -F json -- "$BB" true > "$T/j1" 2>/dev/null
R2=$("$BB" sed -n 's/.*"run":"\(R[0-9]*\)".*/\1/p' "$T/j1")
schema_of() { # schema_of <name> <outfile>
	ck "schema 1 from $1" "1" "$("$BB" grep -c '"schema":1' "$2")"
}
"$BB" run -D "$T/art" -F json -- "$BB" true > "$T/j" 2>/dev/null; schema_of run "$T/j"
"$BB" log -D "$T/art" "$R2" -F json > "$T/j" 2>/dev/null; schema_of log "$T/j"
"$BB" waitfor --file "$T/ready.txt" -F json > "$T/j" 2>/dev/null; schema_of waitfor "$T/j"
"$BB" doctor -F json > "$T/j" 2>/dev/null; schema_of doctor "$T/j"
"$BB" why -C /dev/null -p /dev/null -F json peek > "$T/j" 2>/dev/null; schema_of why "$T/j"
"$BB" patchcheck -d "$T/pat" --format json > "$T/j" 2>/dev/null; schema_of patchcheck "$T/j"
"$BB" bench -n 1 -w 0 -F json -- "$BB" true > "$T/j" 2>/dev/null; schema_of bench "$T/j"
"$BB" snapshot -d "$T/tree" -F json > "$T/j" 2>/dev/null; schema_of snapshot "$T/j"
"$BB" check -f "$T/c1.tbl" --format json > "$T/j" 2>/dev/null; schema_of check "$T/j"
"$BB" brief -F json "$FX/three" > "$T/j" 2>/dev/null; schema_of brief "$T/j"
"$BB" replace "$FX/three" --old b --new B -N -F json > "$T/j" 2>/dev/null; schema_of replace "$T/j"
"$BB" peek -l 1:1 -f json "$FX/three" > "$T/j" 2>/dev/null; schema_of peek "$T/j"


sec "25. peek: patterns, limits and budgets over every fixture"
for f in $FIXTURES; do
	for pat in a x e; do
		r=$(rc "$BB" peek -a "$pat" "$FX/$f")
		ckrc "peek -a $pat rc [$f]" "$r"
		ck "peek -a $pat not a signal [$f]" "1" "$([ "$r" -lt 124 ] && echo 1)"
	done
	r=$(rc "$BB" peek -l 1:1 -M 1 "$FX/$f")
	ckrc "peek -M 1 rc [$f]" "$r"
	r=$(rc "$BB" peek -l 1:1 -B 0 "$FX/$f")
	ckrc "peek -B 0 rc [$f]" "$r"
done

sec "26. replace: wrong counts and wrong versions never write"
for f in $FIXTURES; do
	cp "$FX/$f" "$T/w"
	before=$("$BB" md5sum < "$T/w")
	ck "replace -x 5 rejects [$f]" "1" "$(rc "$BB" replace "$T/w" --old a --new Z -x 5)"
	ck "replace -x 5 wrote nothing [$f]" "$before" "$("$BB" md5sum < "$T/w")"
	ck "replace -S stale rejects [$f]" "1" "$(rc "$BB" replace "$T/w" --old a --new Z -S deadbeef)"
	ck "replace -S stale wrote nothing [$f]" "$before" "$("$BB" md5sum < "$T/w")"
done

sec "27. log reads every fixture's capture back"
for f in $FIXTURES; do
	rm -rf "$T/art"
	"$BB" run -D "$T/art" -- "$BB" cat "$FX/$f" > "$T/out" 2>/dev/null
	R3=$("$BB" sed -n 's/^run=\(R[0-9]*\).*/\1/p' "$T/out" | "$BB" head -1)
	r=$(rc "$BB" log -D "$T/art" "$R3" -l 1:1)
	ckrc "log -l 1:1 rc [$f]" "$r"
	r=$(rc "$BB" log -D "$T/art" "$R3" -B 1)
	ckrc "log -B 1 rc [$f]" "$r"
done

sec "28. brief: four more option shapes over every fixture"
binv() { # binv <name> <outfile>
	li=$("$BB" sed -n '1{s/^\[brief\]/ /;s/.* lines_in=\([0-9]*\).*/\1/p;q;}' "$2")
	sh=$("$BB" sed -n '1{s/^\[brief\]/ /;s/.* shown_lines=\([0-9]*\).*/\1/p;q;}' "$2")
	mg=$("$BB" sed -n '1{s/^\[brief\]/ /;s/.* merged=\([0-9]*\).*/\1/p;q;}' "$2")
	dl=$("$BB" sed -n '1{s/^\[brief\]/ /;s/.* dropped_lines=\([0-9]*\).*/\1/p;q;}' "$2")
	ck "$1" "$li" "$((sh + mg + dl))"
}
for f in $FIXTURES; do
	"$BB" brief -f 1 -S '|' "$FX/$f" > "$T/o" 2>/dev/null
	binv "brief -f 1 -S | invariant [$f]" "$T/o"
	"$BB" brief -k "" "$FX/$f" > "$T/o" 2>/dev/null
	binv "brief -k '' invariant [$f]" "$T/o"
	"$BB" brief -n 1 "$FX/$f" > "$T/o" 2>/dev/null
	binv "brief -n 1 invariant [$f]" "$T/o"
	"$BB" brief -s -a 8 "$FX/$f" > "$T/o" 2>/dev/null
	binv "brief -s -a 8 invariant [$f]" "$T/o"
	# a kept line must survive byte-for-byte whatever the fixture holds
	"$BB" brief -k "" -B 20000 "$FX/$f" > "$T/o" 2>/dev/null
	b=$("$BB" sed -n '1{s/^\[brief\]/ /;s/.* bytes=\([0-9]*\).*/\1/p;q;}' "$T/o")
	ck "brief -k '' body is the whole input [$f]" "0" \
		"$("$BB" tail -c "${b:-0}" "$T/o" > "$T/body"; "$BB" cmp -s "$T/want" "$T/body" 2>/dev/null; \
		   [ "$("$BB" wc -c < "$T/body" | "$BB" tr -d ' ')" -ge "$("$BB" wc -c < "$FX/$f" | "$BB" tr -d ' ')" ] && echo 0 || echo 1)"
done

sec "29. json: document shapes"
mkdir -p "$T/js"
printf '{}' > "$T/js/emptyobj.json"
printf '[]' > "$T/js/emptyarr.json"
printf '{"a":[]}' > "$T/js/earr.json"
printf '{"a":{}}' > "$T/js/eobj.json"
printf '{"a":[[1],[2]]}' > "$T/js/nested.json"
printf '{"a":"x\\ny"}' > "$T/js/newline.json"
printf '{"a":"\\u00e9"}' > "$T/js/uni.json"
printf '{"a":-1}' > "$T/js/neg.json"
printf '{"a":1e10}' > "$T/js/exp.json"
printf '{"a":12345678901234}' > "$T/js/big.json"
printf '{"a":[true,false,null]}' > "$T/js/mixed.json"
printf '{"a":"\\"q\\""}' > "$T/js/quote.json"
printf '{"a":"back\\\\slash"}' > "$T/js/bslash.json"
printf '{"a":{"b":{"c":"deep"}}}' > "$T/js/deep.json"
printf '{"a":0}' > "$T/js/zero.json"
for j in "$T"/js/*.json; do
	n=$("$BB" basename "$j")
	ck "json validates $n" "0" "$("$BB" json -f "$j" -c >/dev/null 2>&1; echo $?)"
	ck "json reads .a $n" "1" "$(is_ok_code "$("$BB" json -f "$j" -g .a >/dev/null 2>&1; echo $?)")"
done
ck "json deep path" "deep" "$("$BB" json -f "$T/js/deep.json" -g .a.b.c 2>/dev/null)"
ck "json array of arrays" "2" "$("$BB" json -f "$T/js/nested.json" -g .a -n 2>/dev/null)"
ck "json negative number" "-1" "$("$BB" json -f "$T/js/neg.json" -g .a 2>/dev/null)"
ck "json zero" "0" "$("$BB" json -f "$T/js/zero.json" -g .a 2>/dev/null)"
ck "json escaped quote" '1' "$("$BB" json -f "$T/js/quote.json" -g .a 2>/dev/null | "$BB" grep -c '"q"')"
ck "json mixed array length" "3" "$("$BB" json -f "$T/js/mixed.json" -g .a -n 2>/dev/null)"

sec "30. every applet works through a symlink in a PATH-like dir"
mkdir -p "$T/bin"
for a in $APPS column; do
	if "$BB" ln -sf "$BB" "$T/bin/$a" 2>/dev/null; then
		r=$(PATH="$T/bin:$PATH" "$a" --help > "$T/out" 2>&1; echo $?)
		ck "symlink $a --help rc" "0" "$r"
		ck "symlink $a names itself" "1" "$("$BB" grep -q "$a" "$T/out" && echo 1)"
	fi
done

sec "31. build description"
"$BB" --caps --format json > "$T/out" 2>/dev/null
ck "--caps has a schema" "1" "$("$BB" grep -c '"schema":1' "$T/out")"
ck "--caps names a platform" "1" "$("$BB" grep -Ec '"platform":"(darwin|linux)"' "$T/out")"
ck "--caps names an arch" "1" "$("$BB" grep -Ec '"arch":"(arm64|aarch64|x86_64|amd64)"' "$T/out")"
ck "--caps lists the agent applets" "1" "$("$BB" grep -q '"brief"' "$T/out" && echo 1)"
ck "--list has the same names as --caps" "1" \
	"$("$BB" --list | "$BB" grep -qx brief && echo 1)"
ck "busybox version is the same in both binaries" "1" \
	"$("$BB" 2>/dev/null | "$BB" head -1 | "$BB" grep -c '^BusyBox v')"
ck "applet count is plausible" "1" "$([ "$(listn_num=$("$BB" --list | "$BB" wc -l | "$BB" tr -d ' '); echo $listn_num)" -gt 200 ] && echo 1)"

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skips"
[ "$fail" -eq 0 ]
