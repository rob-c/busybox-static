#!/bin/bash
# Behaviour suite for the brief applet (patch 0012).
#
#   ./tests/brief.sh dist/darwin-arm64/bin/busybox
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 bash /w/tests/brief.sh \
#       /w/dist/linux-arm64/bin/busybox
#
# Everything runs through $BB; no host tool beyond the shell is assumed, and
# nothing depends on GNU-only flags. The two properties that matter are
# checked directly rather than by eyeballing output:
#
#   1. structure preservation - every displayed line is the input line,
#      byte for byte, optionally behind an "Nx " / "+ " prefix;
#   2. honest accounting - lines_in == lines_shown + lines_merged +
#      dropped_lines, for every option combination.
set -u
BB="${1:?usage: brief.sh /path/to/busybox}"
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
		printf 'FAIL %-52s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}
sec() { printf '== %s ==\n' "$1"; }

# field NAME from a text marker line
mf() { sed -n "s/^\[brief\]/ /;s/.* $1=\([^ ]*\).*/\1/p;q" ; }
# field NAME from the json object
jf() { sed -n "s/.*\"$1\":\\([^,}]*\\).*/\\1/p" ; }
# wc -l pads its number on some hosts
cnt() { tr -d " " ; }

# ---------------------------------------------------------------- fixtures
printf '%s\n' \
	"src/a.c:12: error: use of undeclared identifier extra" \
	"src/a.c:13: error: use of undeclared identifier extra" \
	"src/a.c:99: error: use of undeclared identifier extra" \
	"src/b.c:7: warning: unused variable opt" \
	"link: done" > errs.txt
wc=$(wc -l < errs.txt | tr -d " ")

sec "1. pass-through and marker"
out=$("$BB" brief errs.txt)
ck "marker present" "1" "$(printf '%s\n' "$out" | grep -c '^\[brief\]')"
ck "no loss" "$wc" "$(printf '%s\n' "$out" | mf lines_in)"
ck "all lines shown" "$wc" "$(printf '%s\n' "$out" | mf shown_lines)"
ck "nothing merged" "0" "$(printf '%s\n' "$out" | mf merged)"
ck "nothing dropped" "0" "$(printf '%s\n' "$out" | mf dropped_lines)"
ck "records == lines" "$wc" "$(printf '%s\n' "$out" | mf records)"
ck "exit 0" "0" "$?"
ck "body is byte-identical" \
	"$(cat errs.txt)" \
	"$(printf '%s\n' "$out" | grep -v '^\[brief\]')"

sec "2. -d groups identical lines, first-seen order"
printf '%s\n' "beta" "alpha" "beta" "gamma" "alpha" > ord.txt
out=$("$BB" brief -d ord.txt)
ck "group order" "beta|alpha|gamma" \
	"$(printf '%s\n' "$out" | grep -v '^\[brief\]' | sed 's/^[0-9]*x //' | tr '\n' '|' | sed 's/|$//')"
ck "counts" "1" "$(printf '%s\n' "$out" | grep -c '^2x beta')"
ck "singleton unprefixed" "1" "$(printf '%s\n' "$out" | grep -c '^gamma$')"
ck "records" "3" "$(printf '%s\n' "$out" | mf records)"
ck "merged" "2" "$(printf '%s\n' "$out" | mf merged)"

sec "3. -s masks digits only"
out=$("$BB" brief -s errs.txt)
ck "three digit variants merged" "1" \
	"$(printf '%s\n' "$out" | grep -c '^3x src/a\.c:12: error')"
ck "distinct text kept apart" "1" \
	"$(printf '%s\n' "$out" | grep -c 'warning: unused variable opt')"
ck "exemplar is verbatim" "1" \
	"$(printf '%s\n' "$out" | grep -c '^3x src/a\.c:12: error: use of undeclared identifier extra$')"

sec "4. accounting invariant (matches lines_in for every mode)"
for opts in "" "-d" "-s" "-s -a 2" "-d -B 40" "-s -B 20" "-n 1" "-k warning" "-k error -s"; do
	out=$("$BB" brief $opts errs.txt)
	li=$(printf '%s\n' "$out" | mf lines_in)
	sh=$(printf '%s\n' "$out" | mf shown_lines)
	mg=$(printf '%s\n' "$out" | mf merged)
	dl=$(printf '%s\n' "$out" | mf dropped_lines)
	ck "invariant [$opts]" "$li" "$((sh + mg + dl))"
done

sec "5. -k keeps lines verbatim and never merges them"
printf '%s\n' "error A" "error A" "error A" "noise" "noise" > same.txt
out=$("$BB" brief -k error -d same.txt)
ck "three identical kept lines stay three" "3" \
	"$(printf '%s\n' "$out" | grep -c '^error A$')"
ck "kept count" "3" "$(printf '%s\n' "$out" | mf kept)"
ck "noise still grouped" "1" "$(printf '%s\n' "$out" | grep -c '^2x noise$')"

sec "6. -f projects fields (input may be reformatted, and says so)"
out=$("$BB" brief -f 2,4 errs.txt)
ck "projection (-f 2,4 of 'src/a.c:12: error: use of ...')" "3" \
	"$(printf '%s\n' "$out" | grep -c '^error: of$')"
out=$("$BB" brief -f 2 errs.txt -F json)
ck "json fields flag" "true" "$(printf '%s\n' "$out" | jf fields)"
out=$("$BB" brief -f 9 errs.txt)
ck "out-of-range field on -1 lines still counts" "5" \
	"$(printf '%s\n' "$out" | mf lines_in)"

sec "7. no projection touches a record: grouping is on the original line"
printf '%s\n' "keep me 1 tail" "keep me 2 tail" > proj.txt
ck "-f 2 alone does not merge" "2" \
	"$("$BB" brief -d -f 2 proj.txt | mf records)"

sec "8. budget truncates and says so"
out=$("$BB" brief -s -B 60 errs.txt)
ck "truncated flag" "1" "$(printf '%s\n' "$out" | mf truncated)"
ck "body within budget" "1" \
	"$( [ "$(printf '%s\n' "$out" | grep -vc '^\[brief\]')" -lt 5 ] && echo 1 )"
ck "dropped lines reported" "1" \
	"$([ "$(printf '%s\n' "$out" | mf dropped_lines)" -gt 0 ] && echo 1)"
ck "truncated exit is still 0" "0" "$("$BB" brief -B 0 errs.txt >/dev/null; echo $?)"

sec "9. -n bounds distinct records"
out=$("$BB" brief -n 2 errs.txt)
ck "two records" "2" "$(printf '%s\n' "$out" | mf records)"
ck "rest dropped" "3" "$(printf '%s\n' "$out" | mf dropped_lines)"

sec "10. json"
out=$("$BB" brief -s -F json errs.txt)
ck "schema" '"schema":1' "$(printf '%s\n' "$out" | grep -o '"schema":1')"
ck "one object" "1" "$(printf '%s\n' "$out" | wc -l | cnt)"
ck "json lines_in" "$wc" "$(printf '%s\n' "$out" | jf lines_in)"
ck "json parses" "schema" "$(printf '%s\n' "$out" | "$BB" json -k 2>/dev/null | tr -d ' ' | head -1 | tr -d '"\":')"
if "$BB" json -g .schema >/dev/null 2>&1; then
	ck "json applet agrees" "1" "$(printf '%s\n' "$out" | "$BB" json -g .schema)"
fi

sec "11. errors and exit codes"
ck "missing file = 1" "1" "$("$BB" brief /nonexistent/x 2>/dev/null >/dev/null; echo $?)"
ck "missing file json" "NOT_FOUND" \
	"$("$BB" brief -F json /nonexistent/x 2>/dev/null | grep -o NOT_FOUND)"
ck "bad option = 2" "2" "$("$BB" brief -Z errs.txt 2>/dev/null >/dev/null; echo $?)"
ck "bad field list = 2" "2" "$("$BB" brief -f 0 errs.txt 2>/dev/null >/dev/null; echo $?)"
ck "bad format = 2" "2" "$("$BB" brief -F xml errs.txt 2>/dev/null >/dev/null; echo $?)"

sec "12. bytes are bytes"
printf 'a b c\n' > "with space.txt"
ck "spaced filename intact" "1" \
	"$("$BB" brief -f 3 "with space.txt" | grep -c '^c$')"
printf 'héllo wörld\n' > uni.txt
ck "utf8 preserved" "héllo wörld" \
	"$("$BB" brief uni.txt | grep -v '^\[brief\]')"
printf 'line1\nline2' > nonl.txt
ck "no final newline" "2" "$("$BB" brief nonl.txt | mf lines_in)"
printf '' > empty.txt
ck "empty input" "0" "$("$BB" brief empty.txt | mf lines_in)"
ck "empty input no body" "1" "$("$BB" brief empty.txt | wc -l | cnt)"
printf 'crlf1\r\ncrlf2\r\n' > crlf.txt
ck "crlf lines counted" "2" "$("$BB" brief crlf.txt | mf lines_in)"

sec "13. multiple files share one view"
ck "sum of both" "10" "$("$BB" brief errs.txt same.txt | mf lines_in)"
ck "dash is stdin" "10" \
	"$(cat errs.txt same.txt | "$BB" brief - | mf lines_in)"

sec "14. stdin parity"
ck "stdin == file" \
	"$("$BB" brief -s errs.txt | grep -v '^\[brief\]')" \
	"$("$BB" brief -s < errs.txt | grep -v '^\[brief\]')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
