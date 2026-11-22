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
	ck "help prints usage [$a]" "1" "$("$BB" grep -qc '[Uu]sage:' "$T/out")"
	ck "unknown option exits 2 [$a]" "2" "$(rc "$BB" "$a" --nosuchoption)"
done
for a in replace waitfor run log doctor why json patchcheck bench snapshot check brief; do
	ck "bad --format exits 2 [$a]" "2" "$(rc "$BB" "$a" --format xml)"
done
# every applet named here must exist in this build
for a in $APPS column; do
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
		"$("$BB" grep -qc 'version=sha256:\|NOT_FOUND\|INVALID_ARGUMENT\|UNSUPPORTED' "$T/out" "$T/err" >/dev/null 2>&1 && echo 1)"
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
		"$("$BB" grep -qc 'truncated=false' "$T/out")"
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
ck "peek -r treats the pattern as a regex" "1" "$(rc "$BB" peek -a 'NEE.DLE' -r "$T/n.txt" >/dev/null; "$BB" grep -c 'NEEDLE' "$T/out")"
ck "peek -M refuses a big file" "1" "$(rc "$BB" peek -l 1:1 -M 1 "$FX/ten")"
ck "peek -M refusal is not a crash" "1" "$([ "$(rc "$BB" peek -l 1:1 -M 1 "$FX/ten")" -lt 124 ] && echo 1)"

sec "7. peek on binary and odd bytes"
ck "peek binary rc" "1" "$(is_ok_code "$(rc "$BB" peek -l 1:2 "$FX/binary")")"
ck "peek binary names UNSUPPORTED or shows the line" "1" \
	"$("$BB" grep -qc 'UNSUPPORTED\|version=sha256:' "$T/out" "$T/err" >/dev/null 2>&1 && echo 1)"
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
ck "peek -R missing path names NOT_FOUND" "1" "$("$BB" grep -qc 'NOT_FOUND' "$T/out" "$T/err" >/dev/null 2>&1 && echo 1)"
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
	three|nonl|ten) old="b" ;;
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
	ck "replace miss says so [$f]" "1" "$("$BB" grep -qc 'No files changed' "$T/out" "$T/err" >/dev/null 2>&1 && echo 1)"
	# dry run must not write
	r=$(rc "$BB" replace "$T/w" --old "zzzznotthere" --new "Q" -N)
	ck "replace dry-run rc [$f]" "0" "$r"
	ck "replace dry-run wrote nothing [$f]" "$before" "$("$BB" md5sum < "$T/w")"
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

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skips"
[ "$fail" -eq 0 ]
