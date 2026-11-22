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
# field from a one-line text marker or JSON object
tf() { "$BB" sed -n "1{s/^/ /;s/.* $1=\([^ ]*\).*/\1/p;q;}" "$2"; }
jv() { "$BB" sed -n "s/.*\"$1\":\([^,}]*\).*/\1/p" "$2" | "$BB" head -1; }
# eqfield <name> <field> <short args> <long args>: same extracted field+status
# (for applets whose output carries a run id, duration or path)
eqfield() {
	fld=$2
	# shellcheck disable=SC2086
	"$BB" $3 > "$T/f1" 2>&1; s1=$?
	# shellcheck disable=SC2086
	"$BB" $4 > "$T/f2" 2>&1; s2=$?
	ck "$1: same $fld" "$(tf "$fld" "$T/f1")" "$(tf "$fld" "$T/f2")"
	ck "$1: same status" "$s1" "$s2"
}
# eqform <name> <short args> <long args>: identical stdout+stderr and status
eqform() {
	# shellcheck disable=SC2086
	"$BB" $2 > "$T/f1" 2>&1; s1=$?
	# shellcheck disable=SC2086
	"$BB" $3 > "$T/f2" 2>&1; s2=$?
	ck "$1: same output" "0" "$("$BB" cmp -s "$T/f1" "$T/f2"; echo $?)"
	ck "$1: same status" "$s1" "$s2"
}

# ---- fixtures ------------------------------------------------------------
FX="$T/fx"; mkdir -p "$FX"
: > "$FX/empty"
printf 'x' > "$FX/onebyte"
printf 'only line\n' > "$FX/oneline"
printf 'a\nb\nc\n' > "$FX/three"
printf 'a\nb' > "$FX/nonl"
printf 'a\r\nb\r\nc\r\n' > "$FX/crlf"
printf 'a\000b\nc\n' > "$FX/binary"
printf 'h\303\251llo\nw\303\266rld\n' > "$FX/unicode"
printf '  a  b  \n\tc\td\n' > "$FX/spaces"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > "$FX/ten"
"$BB" awk 'BEGIN{for(i=0;i<10000;i++)printf "x"; printf "\n"}' > "$FX/long"
FIXTURES="empty onebyte oneline three nonl crlf binary unicode spaces ten long"

# =========================================================================
sec "1. every short option equals its long form"
# peek
eqform "peek -l/--lines"     "peek -l 1:2 $FX/ten"          "peek --lines 1:2 $FX/ten"
eqform "peek -B/--max-bytes" "peek -l 1:3 -B 4 $FX/ten"     "peek -l 1:3 --max-bytes 4 $FX/ten"
eqform "peek -a/--around"    "peek -a b $FX/ten"            "peek --around b $FX/ten"
eqform "peek -c/--context"   "peek -a b -c 1 $FX/ten"       "peek --around b --context 1 $FX/ten"
eqform "peek -M/--max-file"  "peek -l 1:1 -M 5 $FX/ten"     "peek -l 1:1 --max-file 5 $FX/ten"
eqform "peek -F/--from-byte" "peek -F 2 $FX/ten"            "peek --from-byte 2 $FX/ten"
eqform "peek -f/--format"    "peek -l 1:1 -f json $FX/ten"  "peek -l 1:1 --format json $FX/ten"
# brief
eqform "brief -d/--dedupe"   "brief -d $FX/three"           "brief --dedupe $FX/three"
eqform "brief -s/--skeleton" "brief -s $FX/ten"             "brief --skeleton $FX/ten"
eqform "brief -k/--keep"     "brief -k a $FX/three"         "brief --keep a $FX/three"
eqform "brief -f/--fields"   "brief -f 1 $FX/spaces"        "brief --fields 1 $FX/spaces"
eqform "brief -S/--sep"      "brief -f 1,2 -S , $FX/spaces" "brief --fields 1,2 --sep , $FX/spaces"
eqform "brief -B/--max-bytes" "brief -B 4 $FX/ten"          "brief --max-bytes 4 $FX/ten"
eqform "brief -n/--max-records" "brief -n 1 $FX/ten"        "brief --max-records 1 $FX/ten"
eqform "brief -a/--samples"  "brief -d -a 2 $FX/three"      "brief --dedupe --samples 2 $FX/three"
eqform "brief -F/--format"   "brief -F json $FX/three"      "brief --format json $FX/three"
# json
printf '{"a":1}' > "$T/j1.json"
eqform "json --format text"  "json -f $T/j1.json -g .a"     "json -f $T/j1.json -g .a --format text"
# replace
printf 'aa\n' > "$T/r1"; cp "$T/r1" "$T/r2"
eqfield "replace -o/--old" changes "replace $T/r1 -o aa -n bb -N" "replace $T/r2 --old aa --new bb --dry-run"
eqfield "replace -x/--expect" changes "replace $T/r1 -o zz -n bb -x 2" "replace $T/r2 --old zz --new bb --expect 2"
# run
eqfield "run -B/--max-bytes" stdout_bytes "run -B 2 -- $BB sh -c 'echo abcd'" "run --max-bytes 2 -- $BB sh -c 'echo abcd'"
eqfield "run -C/--capture-limit" stdout_bytes "run -C 2 -- $BB sh -c 'echo abcd'" "run --capture-limit 2 -- $BB sh -c 'echo abcd'"
# log
rm -rf "$T/art"
"$BB" run -D "$T/art" -- "$BB" sh -c 'echo one; echo two' > "$T/out" 2>/dev/null
R=$(tf run "$T/out")
eqform "log -l/--lines"      "log -D $T/art $R -l 1:1"       "log -D $T/art $R --lines 1:1"
eqform "log -m/--match"      "log -D $T/art $R -m two"       "log -D $T/art $R --match two"
eqform "log -c/--context"    "log -D $T/art $R -m two -c 1"  "log -D $T/art $R --match two --context 1"
eqform "log -s/--stream"     "log -D $T/art $R -s both"      "log -D $T/art $R --stream both"
eqform "log -M/--meta"       "log -D $T/art $R -M"           "log -D $T/art $R --meta"
eqform "log -B/--max-bytes"  "log -D $T/art $R -B 1"         "log -D $T/art $R --max-bytes 1"
# waitfor / doctor / why / patchcheck / bench / snapshot / check / column
printf 'ready\n' > "$T/ready"
eqform "waitfor -f/--file"   "waitfor -f $T/ready -T 1"      "waitfor --file $T/ready --timeout 1"
eqform "waitfor -T/--timeout" "waitfor -f $T/ready -T 1"     "waitfor -f $T/ready --timeout 1"
eqform "doctor -d/--deps"    "doctor -d sh -F json"          "doctor --deps sh --format json"
eqform "why -C/--config"     "why -C /dev/null -p /dev/null peek" "why --config /dev/null --prune /dev/null peek"
mkdir -p "$T/pat"; printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n' > "$T/pat/0001-a.patch"
eqform "patchcheck -d/--dir" "patchcheck -d $T/pat"          "patchcheck --dir $T/pat"
eqfield "bench -n" runs      "bench -n 2 -w 0 -F json -- $BB true" "bench -n 2 -w 0 --format json -- $BB true"
mkdir -p "$T/tree"; printf 'a\n' > "$T/tree/a"
eqform "snapshot -d/--dir"   "snapshot -d $T/tree -F json"   "snapshot --dir $T/tree --format json"
printf 'one | true | 0 |\n' > "$T/c.tbl"
eqform "check -f/--file"     "check -f $T/c.tbl"             "check --file $T/c.tbl"
eqform "check -v/--verbose"  "check -f $T/c.tbl -v"          "check -f $T/c.tbl --verbose"

# =========================================================================
sec "2. byte budgets are monotone and never exceeded"
sweep() { # sweep <applet> <args-before-budget> <field>
	prev=0
	for b in 0 1 2 4 8 16 32 64 128 256 512 1024 4096; do
		# shellcheck disable=SC2086
		"$BB" $1 $2 -B $b > "$T/out" 2>/dev/null
		got=$(tf "$3" "$T/out")
		[ -z "$got" ] && got=$(jv "$3" "$T/out")
		ck "$1 -B $b within budget" "1" "$([ "${got:-0}" -le "$b" ] && echo 1)"
		ck "$1 -B $b monotone" "1" "$([ "${got:-0}" -ge "$prev" ] && echo 1)"
		prev=${got:-0}
	done
}
sweep peek " -l 1:10" shown_bytes
sweep brief "" bytes
sweep run "-D $T/art -- $BB cat $FX/ten" "stdout_bytes"
sweep log "-D $T/art $R" "shown_bytes"

sec "3. compositions: one applet's output is the next one's input"
for f in three nonl crlf binary unicode spaces ten; do
	# peek -> replace -> peek --diff
	cp "$FX/$f" "$T/w"
	if "$BB" peek -l 1:1 "$T/w" > "$T/out" 2>/dev/null; then
		v=$(tf version "$T/out" | "$BB" sed 's/^sha256://')
		r=$(rc "$BB" peek --diff "$v" "$T/w")
		ck "peek --diff unchanged rc [$f]" "0" "$r"
		ck "peek --diff says changed=false [$f]" "1" "$("$BB" grep -c 'changed=false' "$T/out")"
		hit=$("$BB" awk 'NR==1 && length($0)>0 {printf "%s", substr($0,1,1)}' "$FX/$f")
		if [ -n "$hit" ] && "$BB" replace "$T/w" --old "$hit" --new Q >/dev/null 2>&1; then
			r=$(rc "$BB" peek --diff "$v" "$T/w")
			ck "peek --diff changed rc [$f]" "1" "$r"
			ck "peek --diff says changed=true [$f]" "1" "$("$BB" grep -c 'changed=true' "$T/out")"
		else
			skip "peek --diff changed [$f]: first byte is not a unique needle"
		fi
	fi
	# replace --backup keeps a recoverable original
	cp "$FX/$f" "$T/w"
	hit=$("$BB" awk 'NR==1 && length($0)>0 {printf "%s", substr($0,1,1)}' "$FX/$f")
	if [ -n "$hit" ]; then
		if "$BB" replace "$T/w" --old "$hit" --new Q --backup .orig >/dev/null 2>&1; then
			ck "replace --backup wrote the original [$f]" "0" \
				"$("$BB" cmp -s "$FX/$f" "$T/w.orig"; echo $?)"
			ck "replace --backup target differs [$f]" "1" \
				"$([ "$("$BB" cmp -s "$FX/$f" "$T/w"; echo $?)" = 1 ] && echo 1)"
		else
			skip "replace --backup [$f]: first byte is not a unique needle"
		fi
	fi
	# run -> log -> brief: capture, select, then reduce
	rm -rf "$T/art"
	"$BB" run -D "$T/art" -- "$BB" cat "$FX/$f" > "$T/out" 2>/dev/null
	R4=$(tf run "$T/out")
	r=$(rc "$BB" log -D "$T/art" "$R4" -s both)
	ckrc "run->log rc [$f]" "$r"
	"$BB" log -D "$T/art" "$R4" -s both -l 1:2 > "$T/lg" 2>/dev/null
	"$BB" brief -d "$T/lg" > "$T/br" 2>/dev/null
	ck "log->brief rc [$f]" "0" "$?"
	ck "log->brief keeps a marker [$f]" "1" "$("$BB" grep -c '^\[brief\]' "$T/br")"
	# snapshot a tree we just edited
	mkdir -p "$T/sn"
	cp "$FX/$f" "$T/sn/f"
	"$BB" snapshot -d "$T/sn" -o "$T/s1" >/dev/null 2>&1
	"$BB" snapshot -d "$T/sn" -o "$T/s2" >/dev/null 2>&1
	ck "snapshot twice is identical [$f]" "0" "$("$BB" cmp -s "$T/s1" "$T/s2"; echo $?)"
done


# =========================================================================
sec "4. a fault must exit in the table and touch nothing"
APPS="peek replace waitfor run log doctor why json patchcheck bench snapshot check brief"
for a in $APPS; do
	for fault in "--nosuchoption" "-B" "--format xml" "/nonexistent-path-xyz"; do
		r=$(rc "$BB" "$a" $fault)
		ckrc "$a $fault rc" "$r"
		ck "$a $fault not a signal" "1" "$([ "$r" -lt 124 ] && echo 1)"
	done
done

sec "5. malformed numbers are usage errors, and never write"
printf 'aa\n' > "$T/m1"
before=$("$BB" md5sum < "$T/m1")
for bad in abc -1 0x10 ""; do
	ck "brief -B '$bad' rc" "1" "$(is_ok_code "$(rc "$BB" brief -B "$bad" "$FX/three")")"
	ck "peek -B '$bad' rc" "1" "$(is_ok_code "$(rc "$BB" peek -l 1:1 -B "$bad" "$FX/three")")"
	ck "run -B '$bad' rc" "1" "$(is_ok_code "$(rc "$BB" run -B "$bad" -- "$BB" true)")"
	ck "peek -l '$bad' rc" "1" "$(is_ok_code "$(rc "$BB" peek -l "$bad" "$FX/three")")"
	ck "replace -x '$bad' rc" "1" "$(is_ok_code "$(rc "$BB" replace "$T/m1" --old aa --new bb -x "$bad")")"
	ck "replace -x '$bad' wrote nothing" "$before" "$("$BB" md5sum < "$T/m1")"
done
for bad in 1:2:3 : , 1, 3:1 -5:2; do
	r=$(rc "$BB" peek -l "$bad" "$FX/ten")
	ckrc "peek -l '$bad' rc" "$r"
done
for bad in 0 1-0 1,,2 99-1 "1,,,2"; do
	r=$(rc "$BB" brief -f "$bad" "$FX/spaces")
	ckrc "brief -f '$bad' rc" "$r"
done

# =========================================================================
sec "6. brief: option matrix over every fixture shape"
binv() {
	li=$(tf lines_in "$2"); sh=$(tf shown_lines "$2")
	mg=$(tf merged "$2"); dl=$(tf dropped_lines "$2")
	ck "$1" "$li" "$((sh + mg + dl))"
}
for f in $FIXTURES; do
	for opts in "" "-d" "-s" "-k a" "-f 1" "-d -a 4"; do
		# shellcheck disable=SC2086
		r=$(rc "$BB" brief $opts "$FX/$f")
		ck "brief exit [$f $opts]" "0" "$r"
		binv "brief invariant [$f $opts]" "$T/out"
	done
	# a budget of zero shows nothing but still accounts for everything
	r=$(rc "$BB" brief -B 0 "$FX/$f")
	ck "brief -B 0 exit [$f]" "0" "$r"
	ck "brief -B 0 shows nothing [$f]" "0" "$(tf bytes "$T/out")"
	binv "brief -B 0 invariant [$f]" "$T/out"
done

sec "7. peek: range syntax and windows"
for rng in 1 1:1 1:2 :1 :99 1:99 2:2 3:3 10 10:10 9:10 100:200 0:1 2:1 1:0 "" "1:" ":"; do
	r=$(rc "$BB" peek -l "$rng" "$FX/ten")
	ckrc "peek -l '$rng' rc" "$r"
	ck "peek -l '$rng' no signal" "1" "$([ "$r" -lt 124 ] && echo 1)"
done
ck "peek -l 1:2,4:5 shows four lines" "4" \
	"$(rc "$BB" peek -l 1:2,4:5 "$FX/ten" >/dev/null; "$BB" grep -c '^[0-9]* | ' "$T/out")"
ck "peek multi-range separates ranges" "1" "$("$BB" grep -c '^--$' "$T/out")"
ck "peek multi-range header lists both" "1" "$("$BB" grep -c 'lines=1-2,4-5' "$T/out")"
r=$(rc "$BB" peek -l 1:3,2:4 "$FX/ten")
ckrc "peek overlapping ranges rc" "$r"
ck "peek -a with -c 0 shows the match line" "1" \
	"$(rc "$BB" peek -a l5 -c 0 "$FX/ten" >/dev/null; "$BB" grep -c 'l5' "$T/out")"
for p in l1 l10 L5 . 'l[0-9]'; do
	r=$(rc "$BB" peek -a "$p" -r "$FX/ten")
	ckrc "peek -r '$p' rc" "$r"
done
ck "peek -p previews binary as hex" "1" \
	"$(rc "$BB" peek -l 1:1 -p "$FX/binary" >/dev/null; "$BB" grep -c 'version=sha256:' "$T/out")"

sec "8. replace: option matrix"
mk() { printf 'aa\nbb\naa\n' > "$T/w"; }
mk; ck "replace default is one match" "1" "$(rc "$BB" replace "$T/w" --old aa --new ZZ)"
mk; ck "replace -x 2 accepts two" "0" "$(rc "$BB" replace "$T/w" --old aa --new ZZ -x 2)"
mk; ck "replace -x 3 rejects two" "1" "$(rc "$BB" replace "$T/w" --old aa --new ZZ -x 3)"
mk; ck "replace regex matches" "0" "$(rc "$BB" replace "$T/w" --old 'a+' --new Q -r -x 2)"
mk; ck "replace literal does not match regex" "1" "$(rc "$BB" replace "$T/w" --old 'a+' --new Q)"
mk; nb=$("$BB" md5sum < "$T/w")
ck "replace -N rc" "0" "$("$BB" replace "$T/w" --old aa --new ZZ -x 2 -N >/dev/null 2>&1; echo $?)"
ck "replace -N wrote nothing" "$nb" "$("$BB" md5sum < "$T/w")"
mk; ck "replace --backup names the suffix" "1" "$(rc "$BB" replace "$T/w" --old aa --new ZZ -x 2 --backup .bak >/dev/null; "$BB" test -f "$T/w.bak" && echo 1)"
mk; ck "replace --backup is the original" "0" "$("$BB" cmp -s "$T/w.bak" <("$BB" printf 'aa\nbb\naa\n') 2>/dev/null; echo $?)"
for f in three nonl crlf unicode; do
	cp "$FX/$f" "$T/w"
	before=$("$BB" md5sum < "$T/w")
	ck "replace bad regex leaves file [$f]" "1" "$(is_ok_code "$(rc "$BB" replace "$T/w" --old '[' --new x -r)")"
	ck "replace bad regex wrote nothing [$f]" "$before" "$("$BB" md5sum < "$T/w")"
done

sec "9. run and log: exit codes, streams, stdin, pgid"
for code in 0 1 2 3 4 5 6 7 8 9 42 99 100 125; do
	"$BB" run -D "$T/art" -- "$BB" sh -c "exit $code" > "$T/out" 2>/dev/null
	ck "run exit $code passthrough" "$code" "$?"
	ck "run exit $code in metadata" "1" "$("$BB" grep -c "exit_code=$code" "$T/out")"
done
rm -rf "$T/art"
printf 'piped\n' > "$T/in"
"$BB" run -D "$T/art" -i "$T/in" -- "$BB" cat > "$T/out" 2>/dev/null
ck "run -i feeds stdin" "1" "$("$BB" grep -c 'piped' "$T/out")"
ck "run -i reports stdout=6" "1" "$("$BB" grep -c 'stdout=6' "$T/out")"
"$BB" run -D "$T/art" -P -- "$BB" true > "$T/out" 2>/dev/null
ck "run -P prints a pgid" "1" "$("$BB" grep -c '^pgid=[0-9]*' "$T/out")"
ck "run -P pgid is numeric" "1" "$("$BB" sed -n 's/^pgid=\([0-9]*\)$/\1/p' "$T/out" | "$BB" grep -c '^[0-9]')"
"$BB" run -D "$T/art" -s 'echo via-shell; exit 4' > "$T/out" 2>/dev/null
ck "run -s runs through sh" "4" "$?"
ck "run -s captured output" "1" "$("$BB" grep -c 'via-shell' "$T/out")"
"$BB" run -D "$T/art" -d / -- "$BB" pwd > "$T/out" 2>/dev/null
ck "run -d sets the cwd" "1" "$("$BB" grep -c '^/$' "$T/out")"
for f in $FIXTURES; do
	rm -rf "$T/art"
	"$BB" run -D "$T/art" -- "$BB" cat "$FX/$f" > "$T/out" 2>/dev/null
	R5=$(tf run "$T/out")
	r=$(rc "$BB" log -D "$T/art" "$R5" -s both -l 1:1)
	ckrc "log 1:1 rc [$f]" "$r"
	r=$(rc "$BB" log -D "$T/art" "$R5" -M -F json)
	ckrc "log -M json rc [$f]" "$r"
done



# =========================================================================
sec "10. snapshot, check, bench, why, doctor, waitfor: option matrices"
mkdir -p "$T/tr/sub"
printf 'a\n' > "$T/tr/a"; printf 'b\n' > "$T/tr/sub/b"
for i in 1 2 3 4 5; do printf "f$i\n" > "$T/tr/f$i"; done
r=$(rc "$BB" snapshot -d "$T/tr" -F json)
ck "snapshot rc" "0" "$r"
ck "snapshot counts 7 files" "1" "$("$BB" grep -q '"count":7' "$T/out" && echo 1)"
if "$BB" sed -n 's/.*"path":"\([^"]*\)".*/\1/p' "$T/out" | "$BB" sort -c 2>/dev/null; then
	ck "snapshot is sorted" "1" "1"
else
	ck "snapshot is sorted" "1" "0"
fi
"$BB" snapshot -d "$T/tr" -o "$T/sn1" >/dev/null 2>&1
"$BB" snapshot -d "$T/tr" -o "$T/sn2" >/dev/null 2>&1
ck "snapshot is reproducible" "0" "$("$BB" cmp -s "$T/sn1" "$T/sn2"; echo $?)"
printf 'zz\n' > "$T/tr/f1"
"$BB" snapshot -d "$T/tr" -o "$T/sn3" >/dev/null 2>&1
r=$(rc "$BB" snapshot --diff "$T/sn1" "$T/sn3")
ck "snapshot --diff rc" "1" "$r"
ck "snapshot --diff names the change" "1" "$("$BB" grep -c 'f1' "$T/out")"
rm -f "$T/tr/f2"
"$BB" snapshot -d "$T/tr" -o "$T/sn4" >/dev/null 2>&1
"$BB" snapshot --diff "$T/sn3" "$T/sn4" > "$T/out" 2>/dev/null
ck "snapshot --diff reports a removal" "1" "$("$BB" grep -c 'f2' "$T/out")"
ck "snapshot missing dir rc" "1" "$(is_ok_code "$(rc "$BB" snapshot -d "$T/nosuch")")"

printf 'a | true | 0 |\nb | false | 1 |\nc | echo hi | 0 | hi\nd | echo hi | 1 | hi\n' > "$T/tbl"
r=$(rc "$BB" check -f "$T/tbl")
ck "check mixed table rc" "1" "$r"
ck "check counts four" "1" "$("$BB" grep -c 'total=4' "$T/out")"
ck "check counts three passes" "1" "$("$BB" grep -c 'passed=3' "$T/out")"
ck "check counts one failure" "1" "$("$BB" grep -c 'failed=1' "$T/out")"
r=$(rc "$BB" check -f "$T/tbl" -F json)
ck "check json rc" "1" "$r"
ck "check json has results" "1" "$("$BB" grep -c '"failed":1' "$T/out")"
printf 'x | nosuchcommand | 0 |\n' > "$T/tbl2"
r=$(rc "$BB" check -f "$T/tbl2")
ck "check a missing command rc" "1" "$r"

for n in 1 2 3 5; do
	ck "bench -n $n ok" "0" "$(rc "$BB" bench -n $n -w 0 -- "$BB" true)"
	ck "bench -n $n reports runs=$n" "1" "$("$BB" grep -c "runs=$n" "$T/out")"
done
ck "bench -w 1 discards a warmup" "0" "$(rc "$BB" bench -n 1 -w 1 -- "$BB" true)"
ck "bench json units are us" "1" "$(rc "$BB" bench -n 1 -w 0 -F json -- "$BB" true >/dev/null; "$BB" grep -c '"min_us"' "$T/out")"
ck "bench failing cmd exits non-zero" "1" "$([ "$(rc "$BB" bench -n 1 -w 0 -- "$BB" false)" -ne 0 ] && echo 1)"

ck "why unknown applet rc" "1" "$(is_ok_code "$(rc "$BB" why -C /dev/null -p /dev/null nosuchapplet)")"
rc "$BB" why -C /dev/null -p /dev/null -F json peek >/dev/null
ck "why json is one line" "1" "$("$BB" wc -l < "$T/out" | "$BB" tr -d ' ')"
ck "doctor json has deps" "1" "$(rc "$BB" doctor -F json >/dev/null; "$BB" grep -c '"deps"' "$T/out")"
rc "$BB" doctor --build -F json >/dev/null
ck "doctor --build json has build info" "1" "$("$BB" grep -Eq 'build|toolchain|src' "$T/out" && echo 1)"
ck "doctor --build names a compiler" "1" "$("$BB" grep -Eic '"cc"|clang|gcc' "$T/out")"

ck "waitfor --file on a file" "0" "$(rc "$BB" waitfor --file "$T/ready" -T 2)"
ck "waitfor --unix on a dead socket" "3" "$(rc "$BB" waitfor --unix "$T/nosock" -T 1)"
ck "waitfor -e with --http needs a server" "1" "$(is_ok_code "$(rc "$BB" waitfor --http http://127.0.0.1:1 -T 1)")"
ck "waitfor json has elapsed" "1" "$(rc "$BB" waitfor --file "$T/ready" -T 2 -F json >/dev/null; "$BB" grep -c '"elapsed_ms"' "$T/out")"

sec "11. locale does not change bytes"
for loc in C en_US.UTF-8; do
	LC_ALL=$loc "$BB" brief "$FX/unicode" > "$T/l1" 2>/dev/null
	LC_ALL=$loc "$BB" peek -l 1:1 "$FX/unicode" > "$T/l2" 2>/dev/null
	CK_LOC=$(LC_ALL=$loc "$BB" basename "$T/l2")
	ck "brief under LC_ALL=$loc" "0" "$(rc "$BB" brief "$FX/unicode" >/dev/null; LC_ALL=$loc "$BB" cmp -s "$T/l1" "$T/out"; echo $?)"
	ck "peek under LC_ALL=$loc" "0" "$(rc "$BB" peek -l 1:1 "$FX/unicode" >/dev/null; LC_ALL=$loc "$BB" cmp -s "$T/l2" "$T/out"; echo $?)"
	LC_ALL=$loc "$BB" sort "$FX/unicode" > "$T/l3" 2>/dev/null
	ck "sort under LC_ALL=$loc is stable" "0" "$(LC_ALL=$loc "$BB" sort "$FX/unicode" > "$T/l4" 2>/dev/null; LC_ALL=$loc "$BB" cmp -s "$T/l3" "$T/l4"; echo $?)"
done

sec "12. filesystem edges"
long=$(printf 'd%.0s' 1 2 3 4 5 6 7 8); 
LONG="$T/$long/$long/$long/x"
mkdir -p "$(dirname "$LONG")" 2>/dev/null
if printf 'deep\n' > "$LONG" 2>/dev/null; then
	ck "peek a deep path rc" "0" "$(rc "$BB" peek -l 1:1 "$LONG")"
	ck "brief a deep path rc" "0" "$(rc "$BB" brief "$LONG")"
else
	skip "deep path could not be created"
fi
printf 'aa\n' > "$T/ro"; chmod 444 "$T/ro"
r=$(rc "$BB" replace "$T/ro" --old aa --new bb)
ck "replace on a read-only file rc" "1" "$(is_ok_code "$r" ; true)"
ckrc "replace read-only rc in table" "$r"
chmod 644 "$T/ro"
if "$BB" ln -s "$T/loop" "$T/loop" 2>/dev/null; then
	r=$(rc "$BB" peek -l 1:1 "$T/loop")
	ckrc "peek a symlink loop rc" "$r"
fi
mkdir -p "$T/emptydir"
"$BB" snapshot -d "$T/emptydir" -F json > "$T/out" 2>/dev/null
ck "snapshot of an empty dir counts 0" "1" "$("$BB" grep -q '"count":0' "$T/out" && echo 1)"
mkdir -p "$T/many"
i=0; while [ $i -lt 100 ]; do printf 'x\n' > "$T/many/f$i"; i=$((i+1)); done
"$BB" snapshot -d "$T/many" -F json > "$T/out" 2>/dev/null
ck "snapshot counts 100 files" "1" "$("$BB" grep -q '"count":100' "$T/out" && echo 1)"

sec "13. json: path syntax"
cat > "$T/jd.json" <<'EOF'
{"a":{"b":[{"c":1},{"c":2}],"d":"s"},"arr":[10,20],"n":null,"t":false}
EOF
for path in . .a .a.b .a.b[0] .a.b[1].c .a.d .arr .arr[0] .arr[1] .n .t .a.b[0].c; do
	r=$(rc "$BB" json -f "$T/jd.json" -g "$path")
	ckrc "json -g $path rc" "$r"
done
ck "json . -> object" "object" "$("$BB" json -f "$T/jd.json" -g . -t 2>/dev/null)"
ck "json .a.b length" "2" "$("$BB" json -f "$T/jd.json" -g .a.b -n 2>/dev/null)"
ck "json .arr[1]" "20" "$("$BB" json -f "$T/jd.json" -g .arr[1] 2>/dev/null)"
ck "json .a.b[1].c" "2" "$("$BB" json -f "$T/jd.json" -g .a.b[1].c 2>/dev/null)"
ck "json out of range index rc" "1" "$(is_ok_code "$("$BB" json -f "$T/jd.json" -g .arr[9] >/dev/null 2>&1; echo $?)")"
ck "json wrong key rc" "1" "$("$BB" json -f "$T/jd.json" -g .zz >/dev/null 2>&1; echo $?)"
ck "json -k lists keys" "2" "$("$BB" json -f "$T/jd.json" -g .a -k 2>/dev/null | "$BB" wc -l | "$BB" tr -d ' ')"
ck "json -k on an array rc in table" "1" "$(is_ok_code "$("$BB" json -f "$T/jd.json" -g .arr -k >/dev/null 2>&1; echo $?)")"

sec "14. the newest flags over every fixture"
for f in $FIXTURES; do
	"$BB" peek -l 1:1 "$FX/$f" > "$T/out" 2>/dev/null
	v=$(tf version "$T/out" | "$BB" sed 's/^sha256://')
	if [ -n "$v" ]; then
		r=$(rc "$BB" peek --diff "$v" "$FX/$f")
		ck "peek --diff unchanged rc [$f]" "0" "$r"
		ck "peek --diff unchanged body [$f]" "1" "$("$BB" grep -c 'changed=false' "$T/out")"
	else
		skip "peek --diff [$f]: no version (empty or unsupported)"
	fi
	r=$(rc "$BB" peek -l 1:1,2:2 "$FX/$f")
	ckrc "peek multi-range rc [$f]" "$r"
	r=$(rc "$BB" peek -l 1:1 -p "$FX/$f")
	ckrc "peek -p rc [$f]" "$r"
	rm -rf "$T/art"
	"$BB" run -D "$T/art" -i "$FX/$f" -- "$BB" cat > "$T/out" 2>/dev/null
	size=$("$BB" wc -c < "$FX/$f" | "$BB" tr -d ' ')
	ck "run -i delivers $f intact" "1" \
		"$("$BB" grep -q "stdout=$size" "$T/out" && echo 1)"
	R6=$(tf run "$T/out")
	ck "run -i run id present [$f]" "1" "$([ -n "$R6" ] && echo 1)"
done

sec "15. repeatability: same input, same bytes"
for a in $APPS; do
	"$BB" "$a" --help > "$T/h1" 2>&1
	"$BB" "$a" --help > "$T/h2" 2>&1
	ck "help is byte-stable [$a]" "0" "$("$BB" cmp -s "$T/h1" "$T/h2"; echo $?)"
	ck "help names the applet [$a]" "1" "$("$BB" grep -q "$a" "$T/h1" && echo 1)"
done
for f in three nonl crlf binary ten long; do
	"$BB" brief -s "$FX/$f" > "$T/b1" 2>&1
	"$BB" brief -s "$FX/$f" > "$T/b2" 2>&1
	ck "brief -s byte-stable [$f]" "0" "$("$BB" cmp -s "$T/b1" "$T/b2"; echo $?)"
	"$BB" peek -l 1:2 "$FX/$f" > "$T/p1" 2>&1
	"$BB" peek -l 1:2 "$FX/$f" > "$T/p2" 2>&1
	ck "peek byte-stable [$f]" "0" "$("$BB" cmp -s "$T/p1" "$T/p2"; echo $?)"
done


sec "16. end-to-end chains over every fixture"
for f in $FIXTURES; do
	mkdir -p "$T/ch"; cp "$FX/$f" "$T/ch/f"
	# peek -> brief
	"$BB" peek -l 1:2 "$T/ch/f" > "$T/p.txt" 2>/dev/null
	r=$(rc "$BB" brief "$T/p.txt")
	ck "chain peek->brief rc [$f]" "0" "$r"
	ck "chain peek->brief marker [$f]" "1" "$("$BB" grep -c '^\[brief\]' "$T/out")"
	# run -> log -> brief
	rm -rf "$T/art"
	"$BB" run -D "$T/art" -- "$BB" cat "$T/ch/f" > "$T/out" 2>/dev/null
	RY=$(tf run "$T/out")
	"$BB" log -D "$T/art" "$RY" -l 1:1 > "$T/g.txt" 2>/dev/null
	r=$(rc "$BB" brief -d "$T/g.txt")
	ck "chain run->log->brief rc [$f]" "0" "$r"
	ck "chain run->log->brief invariant [$f]" "$(tf lines_in "$T/out")" \
		"$(( $(tf shown_lines "$T/out") + $(tf merged "$T/out") + $(tf dropped_lines "$T/out") ))"
	# run -- brief: the wrapper must capture what the filter printed
	rm -rf "$T/art"
	"$BB" run -D "$T/art" -- "$BB" brief "$T/ch/f" > "$T/out" 2>/dev/null
	ck "chain run(wraps brief) rc [$f]" "0" "$?"
	ck "chain run(wraps brief) captured bytes [$f]" "1" \
		"$([ "$(tf stdout "$T/out")" -gt 0 ] && echo 1)"
	# snapshot -> edit -> snapshot --diff
	"$BB" snapshot -d "$T/ch" -o "$T/s1" >/dev/null 2>&1
	first=$("$BB" awk 'NR==1 && length($0)>0 {printf "%s", substr($0,1,1)}' "$T/ch/f")
	if [ -n "$first" ] && "$BB" replace "$T/ch/f" --old "$first" --new Q >/dev/null 2>&1; then
		"$BB" snapshot -d "$T/ch" -o "$T/s2" >/dev/null 2>&1
		r=$(rc "$BB" snapshot --diff "$T/s1" "$T/s2")
		ck "chain snapshot->replace->diff rc [$f]" "1" "$r"
		ck "chain snapshot->replace->diff sees f [$f]" "1" "$("$BB" grep -c 'f' "$T/out")"
	else
		skip "chain snapshot->replace->diff [$f]: first byte is not a unique needle"
	fi
	# peek -p preview -> brief
	"$BB" peek -l 1:3 -p "$T/ch/f" > "$T/hx" 2>/dev/null
	ck "chain peek -p->brief rc [$f]" "0" "$(rc "$BB" brief "$T/hx")"
done

sec "17. the exit-code table, per applet, for four failure kinds"
for a in $APPS column; do
	# 2: usage
	ck "usage=2 [$a]" "2" "$(rc "$BB" "$a" --nosuchoption)"
	# not a signal, ever
	r=$(rc "$BB" "$a" /nonexistent-xyz)
	ck "no signal [$a]" "1" "$([ "$r" -lt 124 ] && echo 1)"
	ck "code in table [$a]" "1" "$(is_ok_code "$r")"
	# a control byte in an argument must not crash
	r=$(rc "$BB" "$a" "$("$BB" printf 'a\001b')")
	ck "control byte arg is safe [$a]" "1" "$([ "$r" -lt 124 ] && echo 1)"
done

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skips"
[ "$fail" -eq 0 ]
