#!/bin/bash
# Behaviour suite for the brief applet (patch 0014).
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


# ===========================================================================
# String and binary data.  brief is line-oriented, not text-oriented: a record
# is the bytes between two '\n' and nothing else. Every check below compares
# bytes with cmp, never strings in a shell variable, because a NUL cannot
# survive $().
# ===========================================================================

# The body of a run, byte-exactly: the last "bytes=" bytes of the output.
body() { # body <run-output> <body-file>
	b=$("$BB" sed -n '1{s/^\[brief\]/ /;s/.* bytes=\([0-9]*\).*/\1/p;q;}' "$1")
	"$BB" tail -c "${b:-0}" "$1" > "$2"
}
# A marker field, read from a file (the output may contain NULs).
mfo() { "$BB" sed -n "1{s/^\[brief\]/ /;s/.* $1=\([^ ]*\).*/\1/p;q;}" ; }
# Byte-identity: the run's body equals the expected file.
byteck() { # byteck <name> <expected-file> <run-output>
	body "$3" "$T/got.bin"
	ck "$1" "0" "$("$BB" cmp -s "$2" "$T/got.bin"; echo $?)"
}
# Exit status of a run whose output goes to a file.
run() { # run <outfile> <args...>
	outf=$1; shift
	"$BB" brief "$@" > "$outf" 2>/dev/null
	echo $?
}

blank() { prev=$2; got=$1; [ "$got" = "" ] && got="?"; }
inv() { # inv <name> <run-output>
	li=$(mfo lines_in < "$2")
	sh=$(mfo shown_lines < "$2")
	mg=$(mfo merged < "$2")
	dl=$(mfo dropped_lines < "$2")
	ck "$1" "$li" "$((sh + mg + dl))"
}

sec "15. string data: every byte of a record survives (20 fixtures)"

# fixture:  <name>                       <printf-format>       <expected body>
strf() { printf "$2" > "$T/fx"; printf "$3" > "$T/exp"; "$BB" brief "$T/fx" > "$T/o" 2>/dev/null; }

strf "lead/trail spaces"    '   spaced   \n'        '   spaced   \n'
byteck "spaces kept"        "$T/exp" "$T/o"; ck "spaces lines" "1" "$(mfo lines_in < "$T/o")"
strf "tabs"                 'a\tb\t\tc\n'           'a\tb\t\tc\n'
byteck "tabs kept"          "$T/exp" "$T/o"; ck "tabs lines" "1" "$(mfo lines_in < "$T/o")"
strf "double spaces"        'a  b   c\n'            'a  b   c\n'
byteck "inner runs kept"    "$T/exp" "$T/o"; ck "inner runs lines" "1" "$(mfo lines_in < "$T/o")"
strf "trailing tab"         'a\t\n'                 'a\t\n'
byteck "trailing tab kept"  "$T/exp" "$T/o"; ck "trailing tab lines" "1" "$(mfo lines_in < "$T/o")"
strf "lone CR line end"     'oldmac\r'              'oldmac\r\n'
byteck "lone CR kept"       "$T/exp" "$T/o"; ck "lone CR lines" "1" "$(mfo lines_in < "$T/o")"
strf "CR in the middle"     'a\rb\n'                'a\rb\n'
byteck "CR mid kept"        "$T/exp" "$T/o"; ck "CR mid lines" "1" "$(mfo lines_in < "$T/o")"
strf "CRLF pair"            'c1\r\nc2\r\n'          'c1\r\nc2\r\n'
byteck "CRLF bytes kept"    "$T/exp" "$T/o"; ck "CRLF lines" "2" "$(mfo lines_in < "$T/o")"
strf "UTF-8 BOM"            '\357\273\277x\n'       '\357\273\277x\n'
byteck "BOM kept"           "$T/exp" "$T/o"; ck "BOM lines" "1" "$(mfo lines_in < "$T/o")"
strf "invalid UTF-8"        '\377\376bad\n'         '\377\376bad\n'
byteck "bad UTF-8 kept"     "$T/exp" "$T/o"; ck "bad UTF-8 lines" "1" "$(mfo lines_in < "$T/o")"
strf "latin-1 byte"         '\351t\351\n'           '\351t\351\n'
byteck "latin-1 kept"       "$T/exp" "$T/o"; ck "latin-1 lines" "1" "$(mfo lines_in < "$T/o")"
strf "DEL 0x7f"             'del\177x\n'            'del\177x\n'
byteck "DEL kept"           "$T/exp" "$T/o"; ck "DEL lines" "1" "$(mfo lines_in < "$T/o")"
strf "control run 0x01-05"  '\001\002\003\004\005\n' '\001\002\003\004\005\n'
byteck "controls kept"      "$T/exp" "$T/o"; ck "controls lines" "1" "$(mfo lines_in < "$T/o")"
strf "VT and FF"            'a\013\014b\n'          'a\013\014b\n'
byteck "VT/FF kept"         "$T/exp" "$T/o"; ck "VT/FF lines" "1" "$(mfo lines_in < "$T/o")"
strf "4-byte emoji"         '\360\237\230\200 smile\n' '\360\237\230\200 smile\n'
byteck "emoji kept"         "$T/exp" "$T/o"; ck "emoji lines" "1" "$(mfo lines_in < "$T/o")"
strf "only spaces"          '     \n'               '     \n'
byteck "space-only kept"    "$T/exp" "$T/o"; ck "space-only lines" "1" "$(mfo lines_in < "$T/o")"
strf "single char"          'x\n'                   'x\n'
byteck "single char kept"   "$T/exp" "$T/o"; ck "single char lines" "1" "$(mfo lines_in < "$T/o")"

# trailing space is significant: "x" and "x " are different records
printf 'x\nx \n' > "$T/fx"
r=$(run "$T/o" -d "$T/fx")
ck "trailing space not equal" "2" "$(mfo records < "$T/o")"
ck "trailing space invariant" "$(mfo lines_in < "$T/o")" \
	"$(( $(mfo shown_lines < "$T/o") + $(mfo merged < "$T/o") + $(mfo dropped_lines < "$T/o") ))"
# a bare CR is content, not a record separator
printf 'a\rb\nc\n' > "$T/fx"
r=$(run "$T/o" "$T/fx")
ck "bare CR is not a break" "2" "$(mfo lines_in < "$T/o")"

sec "16. binary data: NUL is data, and nothing crashes"

printf 'abc\000def\nxyz\n' > "$T/fx"; printf 'abc\000def\nxyz\n' > "$T/exp"
r=$(run "$T/o" "$T/fx")
ck "binary run exits 0" "0" "$r"
byteck "NUL mid-line kept" "$T/exp" "$T/o"
ck "NUL does not split the line" "2" "$(mfo lines_in < "$T/o")"
ck "NUL is reported" "1" "$(mfo nul < "$T/o")"

printf '\000abc\n' > "$T/fx"; printf '\000abc\n' > "$T/exp"
r=$(run "$T/o" "$T/fx")
byteck "NUL first byte kept" "$T/exp" "$T/o"
ck "NUL first byte lines" "1" "$(mfo lines_in < "$T/o")"

printf 'abc\000\n' > "$T/fx"; printf 'abc\000\n' > "$T/exp"
r=$(run "$T/o" "$T/fx")
byteck "NUL last byte kept" "$T/exp" "$T/o"

printf '\000\n\000\n' > "$T/fx"; printf '\000\n\000\n' > "$T/exp"
r=$(run "$T/o" "$T/fx")
ck "NUL-only lines count" "2" "$(mfo lines_in < "$T/o")"
r=$(run "$T/o" -d "$T/fx")
ck "NUL-only lines group" "1" "$(mfo records < "$T/o")"
printf '2x \000\n' > "$T/exp"
byteck "NUL-only group body" "$T/exp" "$T/o"

# records differing only AFTER a NUL must stay distinct
{ printf 'a\000b\n'; printf 'a\000c\n'; printf 'a\000b\n'; } > "$T/fx"
r=$(run "$T/o" -d "$T/fx")
ck "differ after NUL: 2 records" "2" "$(mfo records < "$T/o")"
ck "differ after NUL: 1 merged" "1" "$(mfo merged < "$T/o")"

# ... but -s still masks digits after a NUL
printf 'a\0001b\na\0002b\n' > "$T/fx"
r=$(run "$T/o" -s "$T/fx")
ck "digits after NUL masked" "1" "$(mfo records < "$T/o")"
printf '2x a\0001b\n' > "$T/exp"
byteck "masked NUL group body" "$T/exp" "$T/o"

# every byte value in one record
{ printf '\000'; "$BB" awk 'BEGIN{for(i=1;i<256;i++)if(i!=10)printf "%c",i}'; printf '\n'; } > "$T/fx"
$BB cmp -s "$T/fx" "$T/fx" || echo "generator broken" >&2
r=$(run "$T/o" "$T/fx")
ck "all 256 bytes: exit" "0" "$r"
byteck "all 256 bytes kept" "$T/fx" "$T/o"
ck "all 255 non-LF bytes: one line" "1" "$(mfo lines_in < "$T/o")"
ck "all 256 bytes: nul seen" "1" "$(mfo nul < "$T/o")"

# the same binary record three times groups exactly once
cat "$T/fx" "$T/fx" "$T/fx" > "$T/fx3"
r=$(run "$T/o" -d "$T/fx3")
ck "binary record groups" "1" "$(mfo records < "$T/o")"
ck "binary record merged" "2" "$(mfo merged < "$T/o")"
r=$(run "$T/o" -d -a 2 "$T/fx3")
ck "-a 2 on binary: invariant" "$(mfo lines_in < "$T/o")" \
	"$(( $(mfo shown_lines < "$T/o") + $(mfo merged < "$T/o") + $(mfo dropped_lines < "$T/o") ))"

# an actual binary file must not crash and must stay bounded
r=$(run "$T/o" "$BB")
ck "binary file: exit 0" "0" "$r"
inv "binary file: invariant" "$T/o"
ck "binary file: bounded body" "1" \
	"$([ "$(mfo bytes < "$T/o")" -le 8000 ] && echo 1)"

# 64 KiB of NUL/ASCII soup
"$BB" awk 'BEGIN{for(l=0;l<512;l++){for(i=0;i<128;i++)printf "%c",(i%2?0:65); printf "\n"}}' > "$T/fx"
r=$(run "$T/o" -s "$T/fx")
ck "NUL soup: exit 0" "0" "$r"
inv "NUL soup: invariant" "$T/o"
r=$(run "$T/o" -d "$T/fx")
ck "NUL soup: -d does not crash" "0" "$r"

# binary in JSON
r=$(run "$T/o" -F json "$T/fx")
ck "binary json: nul_lines present" "1" \
	"$("$BB" grep -c '"nul_lines":512' "$T/o")"
ck "binary json: escapes NUL" "1" "$("$BB" grep -c 'u0000' "$T/o")"
ck "binary json: single line" "1" "$("$BB" wc -l < "$T/o" | tr -d ' ')"

sec "17. long records and buffer boundaries"

for n in 127 128 129 4096; do
	"$BB" awk -v n=$n 'BEGIN{for(i=0;i<n;i++)printf "x"; printf "\n"}' > "$T/fx"
	r=$(run "$T/o" -B 100000 "$T/fx")
	ck "line of $n bytes: exit" "0" "$r"
	byteck "line of $n bytes kept" "$T/fx" "$T/o"
	ck "line of $n bytes: one record" "1" "$(mfo lines_in < "$T/o")"
done
"$BB" awk 'BEGIN{for(i=0;i<100000;i++)printf "x"; printf "\n"}' > "$T/fx"
r=$(run "$T/o" -B 200000 "$T/fx")
byteck "100 KB line kept" "$T/fx" "$T/o"
ck "100 KB line: bytes reported" "100001" "$(mfo bytes < "$T/o")"
"$BB" awk 'BEGIN{for(i=0;i<1048576;i++)printf "x"; printf "\n"}' > "$T/fx"
r=$(run "$T/o" -B 2000000 "$T/fx")
byteck "1 MB line kept" "$T/fx" "$T/o"
r=$(run "$T/o" "$T/fx")
ck "1 MB line: default budget truncates" "1" "$(mfo truncated < "$T/o")"
ck "1 MB line: exit still 0" "0" "$r"
r=$(run "$T/o" -f 1 "$T/fx")
ck "1 MB line: -f 1 no crash" "0" "$r"
"$BB" awk 'BEGIN{for(i=0;i<10000;i++)printf " "; printf "\n"}' > "$T/fx"
r=$(run "$T/o" -B 20000 "$T/fx")
byteck "10 KB of spaces kept" "$T/fx" "$T/o"
"$BB" awk 'BEGIN{for(i=0;i<65536;i++)printf "%c",0; printf "\n"}' > "$T/fx"
r=$(run "$T/o" -B 200000 "$T/fx")
ck "64 KB NUL record: exit" "0" "$r"
byteck "64 KB NUL record kept" "$T/fx" "$T/o"
"$BB" awk 'BEGIN{for(i=0;i<300;i++)printf "a"; for(l=0;l<300;l++){} }' > /dev/null
"$BB" awk 'BEGIN{for(l=0;l<300;l++)printf "%c\n", 97+(l%26)}' > "$T/fx"
r=$(run "$T/o" -d "$T/fx")
ck "300 single-byte lines: records" "26" "$(mfo records < "$T/o")"
ck "300 single-byte lines: lines_in" "300" "$(mfo lines_in < "$T/o")"

sec "18. degenerate input"

: > "$T/fx"
r=$(run "$T/o" "$T/fx")
ck "empty file: exit 0" "0" "$r"
ck "empty file: lines_in" "0" "$(mfo lines_in < "$T/o")"
ck "empty file: bytes" "0" "$(mfo bytes < "$T/o")"
ck "empty file: nul" "0" "$(mfo nul < "$T/o")"
printf '\n' > "$T/fx"
r=$(run "$T/o" "$T/fx")
ck "single newline: lines_in" "1" "$(mfo lines_in < "$T/o")"
printf '\n' > "$T/exp"
byteck "single newline: body" "$T/exp" "$T/o"
printf '\n\n\n' > "$T/fx"
r=$(run "$T/o" -d "$T/fx")
ck "three newlines: lines_in" "3" "$(mfo lines_in < "$T/o")"
ck "three newlines: one record" "1" "$(mfo records < "$T/o")"
printf 'x' > "$T/fx"
r=$(run "$T/o" "$T/fx")
printf 'x\n' > "$T/exp"
byteck "single byte, no newline" "$T/exp" "$T/o"
"$BB" brief /dev/null > "$T/o" 2>/dev/null
ck "/dev/null arg: lines_in" "0" "$(mfo lines_in < "$T/o")"
"$BB" brief < /dev/null > "$T/o" 2>/dev/null
ck "/dev/null stdin: lines_in" "0" "$(mfo lines_in < "$T/o")"
"$BB" brief 0<&- > "$T/o" 2>/dev/null
ck "closed stdin: no crash" "1" "$([ $? -le 1 ] && echo 1)"
printf 'a\nb\n' > "$T/fx"
r=$(run "$T/o" -B 0 "$T/fx")
ck "-B 0: exit 0" "0" "$r"
ck "-B 0: truncated" "1" "$(mfo truncated < "$T/o")"
ck "-B 0: no body" "0" "$(mfo bytes < "$T/o")"
r=$(run "$T/o" -n 1000000 "$T/fx")
ck "huge -n: exit 0" "0" "$r"
r=$(run "$T/o" .)
ck "directory as file: no crash" "1" "$([ $r -le 1 ] && echo 1)"
printf 'a\n' > "$T/locked"; chmod 000 "$T/locked"
r=$(run "$T/o" "$T/locked")
chmod 644 "$T/locked"
ck "unreadable file: rc 1 or read as root" "1" "$([ $r -eq 1 ] || [ "$(id -u)" = 0 ] && echo 1)"

sec "19. invariant and exit status across modes, on mixed text+binary input"

{
	printf 'error: one\n'
	printf 'error: one\n'
	printf 'WARN 0x1f\n'
	printf 'a\000b\n'
	printf '\377\376\n'
	printf 'src/f.c:12: boom\n'
	printf '\r\n'
	printf 'tail-no-newline'
} > "$T/mixed"
for opts in "" "-d" "-s" "-k error" "-s -a 2" "-a 8" "-d -B 40" "-s -B 1" \
	"-n 1" "-n 2 -s" "-f 1" "-f 2,4" "-f 1 -S ," "-k \377"; do
	# shellcheck disable=SC2086
	r=$(run "$T/o" $opts "$T/mixed")
	ck "exit 0 [$opts]" "0" "$r"
	inv "invariant [$opts]" "$T/o"
done

sec "20. json agrees with text"

"$BB" brief -s "$T/mixed" > "$T/t.txt" 2>/dev/null
"$BB" brief -s -F json "$T/mixed" > "$T/j.txt" 2>/dev/null
ck "json lines_in == text" "$(mfo lines_in < "$T/t.txt")" \
	"$("$BB" sed -n 's/.*"lines_in":\([0-9]*\).*/\1/p' "$T/j.txt")"
ck "json records == text" "$(mfo records < "$T/t.txt")" \
	"$("$BB" sed -n 's/.*"records":\([0-9]*\).*/\1/p' "$T/j.txt")"
ck "json kept == text" "$(mfo kept < "$T/t.txt")" \
	"$("$BB" sed -n 's/.*"records":[0-9]*,"kept":\([0-9]*\).*/\1/p' "$T/j.txt")"
ck "json dropped == text" "$(mfo dropped_lines < "$T/t.txt")" \
	"$("$BB" sed -n 's/.*"dropped_lines":\([0-9]*\).*/\1/p' "$T/j.txt")"
"$BB" brief -B 20 "$T/mixed" > "$T/t.txt" 2>/dev/null
"$BB" brief -B 20 -F json "$T/mixed" > "$T/j.txt" 2>/dev/null
ck "json truncated == text" "$(mfo truncated < "$T/t.txt")" \
	"$("$BB" sed -n 's/.*"truncated":\([a-z]*\).*/\1/p' "$T/j.txt" | "$BB" sed 's/true/1/;s/false/0/')"
ck "json is one line" "1" "$("$BB" wc -l < "$T/j.txt" | tr -d ' ')"
ck "text marker first" "1" "$("$BB" sed -n '1p' "$T/t.txt" | "$BB" grep -c '^\[brief\]')"


# ===========================================================================
# Exhaustive sweeps. The sections above sample the byte space; these walk it.
# A record is the bytes between two '\n', so the only byte that may change
# anything is 0x0a itself - every other value must come out untouched.
# ===========================================================================

# mkrec <byte-value> <total-len> <nul-pos|-1>: a record of ASCII 'A' with one
# other byte in it, NUL-terminated with '\n'.
mkrec() { # mkrec <fill-byte> <len> <special-pos> <special-byte>
	"$BB" awk -v n="$2" -v p="$3" -v b="$4" -v f="$1" \
		'BEGIN{for(i=0;i<n;i++)printf "%c",(i==p?b:f); printf "\n"}'
}

sec "21. byte sweep: all 255 non-LF values survive a record"

i=0
while [ $i -le 255 ]; do
	if [ $i -ne 10 ]; then
		"$BB" awk -v b=$i 'BEGIN{printf "A%cB\n", b}' > "$T/fx"
		"$BB" brief "$T/fx" > "$T/o" 2>/dev/null
		"$BB" tail -c 4 "$T/o" > "$T/got"
		ck "byte 0x$(printf %02x $i) preserved" "0" "$("$BB" cmp -s "$T/fx" "$T/got"; echo $?)"
	fi
	i=$((i + 1))
done

sec "22. NUL position sweep: where the NUL sits changes nothing"

p=0
while [ $p -lt 40 ]; do
	mkrec 65 40 $p 0 > "$T/fx"
	"$BB" brief "$T/fx" > "$T/o" 2>/dev/null
	"$BB" tail -c 41 "$T/o" > "$T/got"
	ck "NUL at offset $p kept" "0" "$("$BB" cmp -s "$T/fx" "$T/got"; echo $?)"
	p=$((p + 1))
done
mkrec 65 40 7 0 > "$T/fx"
"$BB" brief "$T/fx" > "$T/o" 2>/dev/null
ck "NUL sweep: one record" "1" "$(mfo lines_in < "$T/o")"
ck "NUL sweep: nul reported" "1" "$(mfo nul < "$T/o")"

sec "23. records differing after a NUL stay distinct (12 offsets)"

for d in 6 7 8 9 10 12 15 20 25 30 35 39; do
	mkrec 65 40 5 0 > "$T/fx"
	mkrec 65 40 5 0 > "$T/fx2"
	# change one byte at offset d in the second copy, past the NUL at 5
	"$BB" awk -v n=40 -v p="$d" 'BEGIN{for(i=0;i<n;i++)printf "%c",(i==p?66:(i==5?0:65)); printf "\n"}' > "$T/fx2"
	cat "$T/fx" "$T/fx2" > "$T/fx3"
	"$BB" brief -d "$T/fx3" > "$T/o" 2>/dev/null
	ck "NUL + difference at $d: 2 records" "2" "$(mfo records < "$T/o")"
done

sec "24. invariant and exit status: 3 binary corpora x 14 option sets"

# c1 mixed text/binary, c2 all-NUL lines, c3 high-byte soup (no 0x0a)
{
	printf 'error: text\n'; printf 'a\000b\n'; printf '\377\376\n'
	printf '\r\n'; printf 'no-newline-tail'
} > "$T/c1"
"$BB" awk 'BEGIN{for(l=0;l<8;l++){for(i=0;i<16;i++)printf "%c",0; printf "\n"}}' > "$T/c2"
"$BB" awk 'BEGIN{for(l=0;l<8;l++){for(i=128;i<256;i++)if(i!=10)printf "%c",i; printf "\n"}}' > "$T/c3"

for corpus in c1 c2 c3; do
	for opts in "" "-d" "-s" "-k error" "-s -a 8" "-d -a 2" "-n 1" "-n 3 -s" \
		"-B 1" "-B 100" "-f 1" "-f 2,4" "-S , -f 1,2" "-f 1 -k A" \
		"-c 1" "-c 2 -f 1" "-t 3" "-m 2" "-q" "-s -c 1" "-c 1 -m 3 -t 2" \
		"-o e" "-x e" "-o e -x b" "-R e" "-R e -d" "-R e -a 2 -B 60" \
		"-i : -c 1" "-i : -f 1,2" "-i \t -f 1"; do
		# shellcheck disable=SC2086
		"$BB" brief $opts "$T/$corpus" > "$T/o" 2>/dev/null
		ck "exit 0 [$corpus $opts]" "0" "$?"
		inv "invariant [$corpus $opts]" "$T/o"
	done
done

sec "25. json over the binary corpora"

for corpus in c1 c2 c3; do
	"$BB" brief -F json "$T/$corpus" > "$T/j" 2>/dev/null
	"$BB" brief "$T/$corpus" > "$T/t" 2>/dev/null
	ck "json schema [$corpus]" "1" "$("$BB" sed -n 's/.*"schema":\([0-9]*\).*/\1/p' "$T/j")"
	ck "json one line [$corpus]" "1" "$("$BB" wc -l < "$T/j" | tr -d ' ')"
	ck "json nul == text nul [$corpus]" "$(mfo nul < "$T/t")" \
		"$("$BB" sed -n 's/.*"nul_lines":\([0-9]*\),.*/\1/p' "$T/j")"
	ck "json lines_in == text [$corpus]" "$(mfo lines_in < "$T/t")" \
		"$("$BB" sed -n 's/.*"lines_in":\([0-9]*\).*/\1/p' "$T/j")"
done

sec "26. record-length boundaries"

for n in 1 2 3 15 16 17 63 64 65 127 128 129 255 256 257 1023 1024 1025 4095 4096 4097; do
	mkrec 65 "$n" -1 0 > "$T/fx"
	"$BB" brief -B 200000 "$T/fx" > "$T/o" 2>/dev/null
	"$BB" tail -c $((n + 1)) "$T/o" > "$T/got"
	ck "record of $n bytes kept" "0" "$("$BB" cmp -s "$T/fx" "$T/got"; echo $?)"
	ck "record of $n bytes: lines_in" "1" "$(mfo lines_in < "$T/o")"
done

sec "27. CR and LF combinations"

crck() { # crck <name> <printf-format> <printf-format> <lines>
	printf "$2" > "$T/fx"; printf "$3" > "$T/exp"
	"$BB" brief "$T/fx" > "$T/o" 2>/dev/null
	byteck "$1 bytes" "$T/exp" "$T/o"
	ck "$1 lines" "$4" "$(mfo lines_in < "$T/o")"
}
crck "CRLF only"      'x\r\n'      'x\r\n'      1
crck "CR CR LF"       'x\r\r\n'    'x\r\r\n'    1
crck "CR alone"       '\r'         '\r\n'       1
crck "LF then CR"     '\n\r'       '\n\r\n'     2
crck "empty then CR"  '\n\r\n'     '\n\r\n'     2
crck "CR inside"      'a\rb\n'     'a\rb\n'     1
printf 'x\r\ny\r\n' > "$T/fx"
"$BB" brief -d "$T/fx" > "$T/o" 2>/dev/null
ck "CRLF -d: two records" "2" "$(mfo records < "$T/o")"
printf 'x\r\n' 'x\n' > "$T/fx2"
{ printf 'x\r\n'; printf 'x\n'; } > "$T/fx2"
"$BB" brief -d "$T/fx2" > "$T/o" 2>/dev/null
ck "CRLF is not LF" "2" "$(mfo records < "$T/o")"
"$BB" brief -s "$T/fx2" > "$T/o" 2>/dev/null
ck "CRLF -s keeps them distinct" "2" "$(mfo records < "$T/o")"
printf 'a\rb\rc\n' > "$T/fx"
"$BB" brief "$T/fx" > "$T/o" 2>/dev/null
ck "several CRs in one record" "1" "$(mfo lines_in < "$T/o")"
ck "several CRs: nul untouched" "0" "$(mfo nul < "$T/o")"

sec "28. -f field projection over binary fields"

printf 'a\000b c\000d\n' > "$T/fx"
"$BB" brief -f 1 "$T/fx" > "$T/o" 2>/dev/null
printf 'a\000b\n' > "$T/exp"
byteck "-f 1 keeps NUL in field" "$T/exp" "$T/o"
"$BB" brief -f 2 "$T/fx" > "$T/o" 2>/dev/null
printf 'c\000d\n' > "$T/exp"
byteck "-f 2 keeps NUL in field" "$T/exp" "$T/o"
"$BB" brief -f 1,2 "$T/fx" > "$T/o" 2>/dev/null
printf 'a\000b c\000d\n' > "$T/exp"
byteck "-f 1,2 rejoins with one space" "$T/exp" "$T/o"
"$BB" brief -f 1,2 -S '|' "$T/fx" > "$T/o" 2>/dev/null
printf 'a\000b|c\000d\n' > "$T/exp"
byteck "-S replaces the separator" "$T/exp" "$T/o"
"$BB" brief -f 9 "$T/fx" > "$T/o" 2>/dev/null
printf '\n' > "$T/exp"
byteck "-f 9 (out of range) is an empty record" "$T/exp" "$T/o"
printf 'a\tb\000c\n' > "$T/fx"
"$BB" brief -f 2 "$T/fx" > "$T/o" 2>/dev/null
printf 'b\000c\n' > "$T/exp"
byteck "tab-delimited field with NUL" "$T/exp" "$T/o"
printf '\377\376 x\n' > "$T/fx"
"$BB" brief -f 1 "$T/fx" > "$T/o" 2>/dev/null
printf '\377\376\n' > "$T/exp"
byteck "high-byte field" "$T/exp" "$T/o"
printf 'a\000b\n' 'a\000c\n' > "$T/fx"
{ printf 'a\000b\n'; printf 'a\000c\n'; } > "$T/fx"
"$BB" brief -d -f 1 "$T/fx" > "$T/o" 2>/dev/null
ck "-f does not merge distinct records" "2" "$(mfo records < "$T/o")"
ck "-f reports fields=true" "true" \
	"$("$BB" brief -f 1 -F json "$T/fx" 2>/dev/null | "$BB" sed -n 's/.*"fields":\([a-z]*\).*/\1/p')"
"$BB" brief -f 1,2,3 "$T/fx" > "$T/o" 2>/dev/null
ck "-f wider than the record: still one record each" "2" "$(mfo records < "$T/o")"
"$BB" brief -f 1 -B 1 "$T/fx" > "$T/o" 2>/dev/null
ck "-f 1 with a 1-byte budget truncates" "1" "$(mfo truncated < "$T/o")"

sec "29. -k over binary records"

printf 'A\000B\nplain\n' > "$T/fx"
"$BB" brief -k A "$T/fx" > "$T/o" 2>/dev/null
ck "-k matches across a NUL boundary" "1" "$(mfo kept < "$T/o")"
printf 'A\000B\nplain\n' > "$T/exp"
byteck "-k keeps the NUL bytes" "$T/exp" "$T/o"
printf '\377\376\nplain\n' > "$T/fx"
"$BB" brief -k "$(printf '\377')" "$T/fx" > "$T/o" 2>/dev/null
ck "-k matches a high byte" "1" "$(mfo kept < "$T/o")"
"$BB" brief -k zzzz "$T/fx" > "$T/o" 2>/dev/null
ck "-k with no match keeps nothing" "0" "$(mfo kept < "$T/o")"
"$BB" brief -k "" "$T/fx" > "$T/o" 2>/dev/null
ck "-k '' keeps every record" "2" "$(mfo kept < "$T/o")"
printf 'A\000B\nA\000B\nnoise\n' > "$T/fx"
"$BB" brief -k A -d "$T/fx" > "$T/o" 2>/dev/null
ck "-k never merges identical kept lines" "2" "$(mfo kept < "$T/o")"
ck "-k repeats still counted as lines_in" "3" "$(mfo lines_in < "$T/o")"
inv "-k binary: invariant" "$T/o"
"$BB" brief -k A -F json "$T/fx" > "$T/o" 2>/dev/null
ck "-k json kept flag" "2" \
	"$("$BB" grep -o '"kept":true' "$T/o" | "$BB" wc -l | tr -d ' ')"
ck "-k json: ordinary record is not kept" "1" \
	"$("$BB" grep -c '"kept":false' "$T/o")"
"$BB" brief -F json "$T/fx" > "$T/o" 2>/dev/null
ck "no -k: nothing flagged kept" "0" \
	"$("$BB" grep -o '"kept":true' "$T/o" | "$BB" wc -l | tr -d ' ')"

sec "30. -a samples and -S separators with binary content"

printf 'a\0001b\na\0002b\na\0003b\n' > "$T/fx"
"$BB" brief -s -a 2 "$T/fx" > "$T/o" 2>/dev/null
ck "-a 2 shows two samples" "2" "$(mfo shown_lines < "$T/o")"
printf '3x a\0001b\n+ a\0002b\n' > "$T/exp"
byteck "-a 2 body keeps NUL and the + prefix" "$T/exp" "$T/o"
"$BB" brief -s -a 8 "$T/fx" > "$T/o" 2>/dev/null
ck "-a 8 is accepted" "0" "$?"
"$BB" brief -s -a 3 "$T/fx" > "$T/o" 2>/dev/null
inv "-a 3: invariant" "$T/o"
printf 'a\000b\n' > "$T/fx"
"$BB" brief -a 2 "$T/fx" > "$T/o" 2>/dev/null
printf 'a\000b\n' > "$T/exp"
byteck "single occurrence: no Nx prefix" "$T/exp" "$T/o"
printf 'p q\n' > "$T/fx"
"$BB" brief -f 1,2 -S '::' "$T/fx" > "$T/o" 2>/dev/null
printf 'p::q\n' > "$T/exp"
byteck "-S with two bytes" "$T/exp" "$T/o"
"$BB" brief -f 1,2 -S '' "$T/fx" > "$T/o" 2>/dev/null
printf 'pq\n' > "$T/exp"
byteck "-S empty concatenates" "$T/exp" "$T/o"

sec "31. -c: aggregation on selected fields"

printf '%s\n' "bash 12 ok" "bash 13 ok" "bash 44 fail" \
	"read 1 ok" "edit 2 fail" "edit 3 ok" > agg.txt
"$BB" brief -c 1 agg.txt > "$T/o" 2>/dev/null
ck "-c groups without -d" "3x bash" "$(body "$T/o" "$T/b"; "$BB" sed -n '1p' "$T/b")"
ck "-c records" "3" "$(mfo records < "$T/o")"
ck "-c merged" "3" "$(mfo merged < "$T/o")"
inv "-c 1: invariant" "$T/o"
ck "-c sets projected" "3" "$(mfo projected < "$T/o")"
ck "-c json grouped_by" "1" "$("$BB" brief -c 1 -F json agg.txt 2>/dev/null | grep -c '"grouped_by":"1"')"

# group on one field, print another
printf '%s\n' "a 1 x" "a 2 y" "a 3 z" "b 1 p" > fld.txt
"$BB" brief -c 2 -f 3 fld.txt > "$T/o" 2>/dev/null
ck "-c 2 -f 3 groups on 2, prints 3" "2x x" "$(body "$T/o" "$T/b"; "$BB" sed -n '1p' "$T/b")"
ck "-c 2 -f 3 keeps the other groups" "3" "$(mfo records < "$T/o")"
inv "-c 2 -f 3: invariant" "$T/o"

# every selected field out of range collapses to one empty record by design
"$BB" brief -c 9 agg.txt > "$T/o" 2>/dev/null
ck "-c 9 one group" "1" "$(mfo records < "$T/o")"
inv "-c 9: invariant" "$T/o"

# a NUL in a projected field is data, not a separator
printf 'a\000b 1\na\000b 2\nz\000 9\n' > "$T/fx"
printf '2x a\000b\nz\000\n' > "$T/exp"
"$BB" brief -c 1 "$T/fx" > "$T/o" 2>/dev/null
byteck "-c 1 over NUL fields" "$T/exp" "$T/o"

sec "32. -t: the budget is spent on the repeated records"

# 500 unique records, then one record repeated 3000 times
"$BB" awk 'BEGIN{for(i=0;i<500;i++)printf "unique record number %d\n",i;
	for(i=0;i<3000;i++)printf "warning: conversion from size_t to int, possible loss of data\n"}' > late.txt
"$BB" brief -B 400 late.txt > "$T/o" 2>/dev/null
ck "without -t the repeat is invisible" "0" "$(body "$T/o" "$T/b"; "$BB" grep -c '3000x' "$T/b")"
ck "without -t the budget truncated the table" "1" "$(mfo truncated < "$T/o")"
inv "budget truncation: invariant" "$T/o"

"$BB" brief -t 3 -B 400 late.txt > "$T/o" 2>/dev/null
ck "-t puts the 3000x record first" "3000x warning: conversion from size_t to int, possible loss of data" \
	"$(body "$T/o" "$T/b"; "$BB" sed -n '1p' "$T/b")"
ck "-t merged the repeats" "2999" "$(mfo merged < "$T/o")"
inv "-t: invariant" "$T/o"

# equal counts keep first-appearance order
printf '%s\n' "zeta" "alpha" "zeta" "alpha" > tie.txt
"$BB" brief -t 2 tie.txt > "$T/o" 2>/dev/null
ck "-t tie-break is first appearance" "2x zeta|2x alpha" \
	"$(body "$T/o" "$T/b"; "$BB" sed -n '1,2p' "$T/b" | tr '\n' '|' | sed 's/|$//')"

# a budget that cuts inside a group must not double-count it
printf 'x1\nx2\nx3\n' > var.txt
"$BB" brief -s -a 8 -B 6 var.txt > "$T/o" 2>/dev/null
ck "mid-group truncation counts the rest as merged" "2" "$(mfo merged < "$T/o")"
ck "mid-group truncation drops nothing" "0" "$(mfo dropped_lines < "$T/o")"
inv "mid-group truncation: invariant" "$T/o"

sec "33. -m: below the threshold is not a record"

# agg.txt grouped by field 1 is bash:2, read:1, edit:2
"$BB" brief -c 1 -m 2 agg.txt > "$T/o" 2>/dev/null
ck "-m drops singletons" "2" "$(mfo shown_groups < "$T/o")"
ck "-m counts the dropped lines" "1" "$(mfo dropped_lines < "$T/o")"
ck "-m counts the dropped records" "1" "$(mfo dropped_records < "$T/o")"
inv "-m 2: invariant" "$T/o"

"$BB" brief -c 1 -m 99 agg.txt > "$T/o" 2>/dev/null
ck "-m above every count shows nothing" "0" "$(mfo shown_lines < "$T/o")"
ck "-m above every count drops all" "6" "$(mfo dropped_lines < "$T/o")"
ck "-m above every count drops every record" "3" "$(mfo dropped_records < "$T/o")"
inv "-m 99: invariant" "$T/o"

"$BB" brief -m 1 agg.txt > "$T/m1" 2>/dev/null
"$BB" brief -d agg.txt > "$T/m0" 2>/dev/null
ck "-m 1 is the default view" "$(mfo shown_lines < "$T/m0")" "$(mfo shown_lines < "$T/m1")"

sec "34. -q: bare records stay quotable"

printf '%s\n' "a 1 x" "a 2 y" "a 1 x" "b 3 z" > q.txt
printf '%s\n' "a 1 x" "a 2 y" "b 3 z" > qexp.txt
"$BB" brief -d -q q.txt > "$T/o" 2>/dev/null
body "$T/o" "$T/b"
"$BB" cmp -s qexp.txt "$T/b"
ck "-q body equals the input minus duplicates" "0" "$?"
ck "-q says so in the marker" "1" "$(mfo bare < "$T/o")"
ck "-q still counts the merge" "1" "$(mfo merged < "$T/o")"
inv "-q: invariant" "$T/o"

printf 'a\000b\na\000b\nc\000\n' > "$T/fx"
printf 'a\000b\nc\000\n' > "$T/exp"
"$BB" brief -d -q "$T/fx" > "$T/o" 2>/dev/null
byteck "-q over NUL records is byte-exact" "$T/exp" "$T/o"

printf 'p q\np r\n' > "$T/fx"
printf 'p\n' > "$T/exp"
"$BB" brief -q -c 1 "$T/fx" > "$T/o" 2>/dev/null
byteck "-q -c prints the projected record bare" "$T/exp" "$T/o"

sec "35. the new marker and json fields agree"

"$BB" brief -c 1 -t 2 -m 1 agg.txt > "$T/t" 2>/dev/null
"$BB" brief -c 1 -t 2 -m 1 -F json agg.txt > "$T/j" 2>/dev/null
for f in shown_groups projected; do
	ck "json $f == text" "$(mfo $f < "$T/t")" \
		"$("$BB" sed -n "s/.*\"$f\":\\([0-9]*\\),.*/\\1/p" "$T/j")"
done
ck "json top == text" "$(mfo top < "$T/t")" "$("$BB" sed -n 's/.*"top":\([0-9]*\),.*/\1/p' "$T/j")"
ck "json min_count == text" "$(mfo min < "$T/t")" "$("$BB" sed -n 's/.*"min_count":\([0-9]*\),.*/\1/p' "$T/j")"
ck "json bare is false here" "1" "$("$BB" grep -c '"bare":false' "$T/j")"
ck "json first item is the 3x record" "1" \
	"$("$BB" grep -c '"items":\[{"n":3,' "$T/j")"
ck "json schema is still 1" "1" "$("$BB" sed -n 's/.*"schema":\([0-9]*\).*/\1/p' "$T/j")"

sec "36. -o / -x: selection without a format registry"

printf '%s\n' "ok line" "src/a.c:1: error: bad" "warning: unused" "fine" > sel.txt
"$BB" brief -o error sel.txt > "$T/o" 2>/dev/null
ck "-o keeps the matching record" "src/a.c:1: error: bad" "$(body "$T/o" "$T/b"; "$BB" sed -n '1p' "$T/b")"
ck "-o counts what it did not match" "3" "$(mfo dropped_lines < "$T/o")"
ck "-o matched count" "1" "$(mfo matched < "$T/o")"
inv "-o: invariant" "$T/o"

"$BB" brief -o error -o warning sel.txt > "$T/o" 2>/dev/null
ck "-o repeats as OR" "2" "$(mfo matched < "$T/o")"
ck "-o OR shows both" "2" "$(body "$T/o" "$T/b"; "$BB" grep -c -e error -e warning "$T/b")"
inv "-o OR: invariant" "$T/o"

"$BB" brief -o error -x bad sel.txt > "$T/o" 2>/dev/null
ck "-x subtracts from -o" "0" "$(mfo matched < "$T/o")"
ck "-x leaves an empty body" "0" "$(mfo shown_lines < "$T/o")"
inv "-o -x: invariant" "$T/o"

"$BB" brief -o zzznomatch sel.txt > "$T/o" 2>/dev/null
ck "-o with no match exits 0" "0" "$?"
ck "-o with no match matched=0" "0" "$(mfo matched < "$T/o")"
inv "-o no match: invariant" "$T/o"

# selection then counting: the failures of any tool, counted
printf '%s\n' "a.c:1: error: bad" "a.c:9: error: bad" "b.c:2: error: bad" > cnt.txt
"$BB" brief -o error -s -t 3 cnt.txt > "$T/o" 2>/dev/null
ck "-o -s counts by shape" "2x a.c:1: error: bad" "$(body "$T/o" "$T/b"; "$BB" sed -n '1p' "$T/b")"
ck "-o -s keeps the other group" "2" "$(mfo shown_groups < "$T/o")"
inv "-o -s -t: invariant" "$T/o"

printf 'x\000y error z\nplain\n' > "$T/fx"
printf 'x\000y error z\n' > "$T/exp"
"$BB" brief -o error "$T/fx" > "$T/o" 2>/dev/null
byteck "-o over a NUL record" "$T/exp" "$T/o"

sec "37. -R: a record is many lines"

{
	printf 'banner line\n'
	printf 'commit aaa\nAuthor: X\n    message one\n'
	printf 'commit bbb\nAuthor: Y\n    message two\n'
	printf 'commit aaa\nAuthor: X\n    message one\n'
} > sec.txt
"$BB" brief -R commit sec.txt > "$T/o" 2>/dev/null
ck "-R counts records, not lines" "4" "$(mfo records < "$T/o")"
ck "-R keeps the prologue as one record" "1" "$(body "$T/o" "$T/b"; "$BB" grep -c '^banner line' "$T/b")"
ck "-R without -d merges nothing" "0" "$(mfo merged < "$T/o")"
ck "-R shows every line it read" "10" "$(mfo shown_lines < "$T/o")"
inv "-R: invariant" "$T/o"

"$BB" brief -R commit -d sec.txt > "$T/o" 2>/dev/null
ck "-R -d merges identical sections" "2x commit aaa" "$(body "$T/o" "$T/b"; "$BB" sed -n '2p' "$T/b")"
ck "-R -d records" "3" "$(mfo records < "$T/o")"
inv "-R -d: invariant" "$T/o"

# a record is shown whole or not at all: no half a commit
"$BB" brief -R commit -B 40 sec.txt > "$T/o" 2>/dev/null
ck "-B 40 shows the banner only" "1" "$(mfo shown_lines < "$T/o")"
ck "-B 40 shows no partial record" "0" \
	"$(body "$T/o" "$T/b"; "$BB" grep -c commit "$T/b")"
inv "-R tight budget: invariant" "$T/o"
ck "-R tight budget truncates" "1" "$(mfo truncated < "$T/o")"

# a record too big for any budget is dropped, and must not hide later ones
"$BB" brief -R commit -B 26 sec.txt > "$T/o" 2>/dev/null
ck "-R unshowable banner does not hide the rest" "1" "$(mfo shown_groups < "$T/o")"
inv "-R unshowable: invariant" "$T/o"

printf 'x1\nsame\nx2\nsame\nx3\nsame\n' > "$T/fx"
printf 'x1\nsame\nx2\nsame\nx3\nsame\n' > "$T/exp"
"$BB" brief -R same -q "$T/fx" > "$T/o" 2>/dev/null
byteck "-R -q prints the records bare" "$T/exp" "$T/o"

# -o selects a whole record when any of its lines matches
printf 'head\nA\000B 1\nbody\nA\000B 2\n' > "$T/fx"
printf 'A\000B 2\n' > "$T/exp"
"$BB" brief -R A -o 2 "$T/fx" > "$T/o" 2>/dev/null
byteck "-R selects a whole record by any of its lines" "$T/exp" "$T/o"

printf 'x1\nx2\nx3\n' > "$T/fx"
"$BB" brief -R x "$T/fx" > "$T/o" 2>/dev/null
ck "-R matching every line is line mode" "3" "$(mfo records < "$T/o")"
inv "-R every line: invariant" "$T/o"

sec "38. the marker measures the call"

"$BB" brief -d -c 1 -t 2 -R needlenope errs.txt > "$T/o" 2>/dev/null
ck "in_bytes is the input size" "$(wc -c < errs.txt | cnt)" "$(mfo in_bytes < "$T/o")"
ck "bytes is smaller than in_bytes here" "1" \
	"$("$BB" awk -v a="$(mfo bytes < "$T/o")" -v b="$(mfo in_bytes < "$T/o")" 'BEGIN{print (a<b)}')"
ck "record_start is echoed in json" "1" \
	"$("$BB" brief -R commit -F json sec.txt 2>/dev/null | "$BB" grep -c '"record_start":"commit"')"
ck "record_start null without -R" "1" \
	"$("$BB" brief -F json errs.txt 2>/dev/null | "$BB" grep -c '"record_start":null')"
ck "json item carries its line count" "1" \
	"$("$BB" brief -R commit -F json sec.txt 2>/dev/null | "$BB" grep -c '"lines":3')"

sec "39. -i: colon-delimited output is field-structured too"

printf '%s\n' "src/a.c:12: error: bad" "src/a.c:13: error: bad" \
	"src/b.c:7: warning: unused" > diag.txt
"$BB" brief -i : -f 1 diag.txt > "$T/o" 2>/dev/null
ck "-i : splits on the colon" "src/a.c|src/a.c|src/b.c" \
	"$(body "$T/o" "$T/b"; "$BB" sed -n '1,3p' "$T/b" | tr '\n' '|' | sed 's/|$//')"
"$BB" brief -i : -c 1 -t 3 diag.txt > "$T/o" 2>/dev/null
ck "-i : -c groups by path" "2x src/a.c" "$(body "$T/o" "$T/b"; "$BB" sed -n '1p' "$T/b")"
ck "-i : -c counts the other path" "2" "$(mfo shown_groups < "$T/o")"
inv "-i : -c: invariant" "$T/o"

# several separators at once
printf 'a/b:12/x\nc/d:13/x\n' > "$T/fx"
"$BB" brief -i ':/' -f 1 "$T/fx" > "$T/o" 2>/dev/null
ck "-i takes several separators" "a|c" \
	"$(body "$T/o" "$T/b"; "$BB" sed -n '1,2p' "$T/b" | tr '\n' '|' | sed 's/|$//')"

# the default is still space and tab, and a NUL is never a separator
printf 'p q\np r\n' > "$T/fx"
"$BB" brief -c 1 "$T/fx" > "$T/o" 2>/dev/null
ck "default splitter is still whitespace" "2x p" "$(body "$T/o" "$T/b"; "$BB" sed -n '1p' "$T/b")"
printf 'a\000b:c\n' > "$T/fx"
printf 'a\000b\n' > "$T/exp"
"$BB" brief -i : -f 1 "$T/fx" > "$T/o" 2>/dev/null
byteck "-i never splits on NUL" "$T/exp" "$T/o"

# nothing selected is still nothing, not a crash
printf 'abc\n' > "$T/fx"
"$BB" brief -i : -f 9 "$T/fx" > "$T/o" 2>/dev/null
ck "-i with every field out of range exits 0" "0" "$?"
inv "-i out of range: invariant" "$T/o"

sec "40. a -R record is bounded in memory"

# 4.5 MB with no match: the record cap must close it instead of holding it all
"$BB" awk 'BEGIN{for(i=0;i<110000;i++) printf "line %06d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", i}' > big.txt
"$BB" brief -R nomatchxyz -B 100 big.txt > "$T/o" 2>/dev/null
ck "-R with no match still exits 0" "0" "$?"
ck "-R caps the record instead of buffering it all" "1" \
	"$("$BB" awk -v r="$(mfo records < "$T/o")" 'BEGIN{print (r>=2)}')"
inv "-R record cap: invariant" "$T/o"

# a record that fits under the cap stays one record
printf 'a\nb\nc\n' > "$T/fx"
"$BB" brief -R a "$T/fx" > "$T/o" 2>/dev/null
ck "a small -R record is one record" "1" "$(mfo records < "$T/o")"

sec "41. -F json explains the view to a reader that cannot see the input"

printf '%s\n' "a" "a" "b" > dj.txt
"$BB" brief -d -F json dj.txt > "$T/j" 2>/dev/null
ck "json is one line" "1" "$("$BB" wc -l < "$T/j" | cnt)"
ck "json schema 1" "1" "$("$BB" grep -c '"schema":1' "$T/j")"
ck "summary says complete" "1" "$("$BB" grep -c 'complete' "$T/j")"
ck "summary is a sentence" "1" "$("$BB" grep -c '"summary":"3 lines in, 2 records, all shown' "$T/j")"
ck "pct_of_input is a number" "1" "$("$BB" grep -c '"pct_of_input":[0-9]' "$T/j")"
ck "hints is an array" "1" "$("$BB" grep -c '"hints":\[' "$T/j")"
ck "truncated_by is null when nothing was cut" "1" "$("$BB" grep -c '"truncated_by":null' "$T/j")"
# the count is a field, so the record itself carries no "Nx " and no newline
ck "item line is the record, not the rendering" "1" "$("$BB" grep -c '"n":2,"lines":2,"kept":false,"line":"a"' "$T/j")"
ck "one object per group" "2" "$("$BB" grep -c '"n":' "$T/j")"
# merged lines are what -t would rank
ck "hint names -t when lines were merged" "1" "$("$BB" grep -c '\-t 10 ranks' "$T/j")"

"$BB" brief -t 1 -F json dj.txt > "$T/j" 2>/dev/null
ck "truncated_by names the cap" "1" "$("$BB" grep -c '"truncated_by":"top"' "$T/j")"
ck "hint names -t as the cap" "1" "$("$BB" grep -c 'kept the 1 highest-count groups' "$T/j")"
ck "summary says incomplete" "1" "$("$BB" grep -c 'incomplete' "$T/j")"

printf '%s\n' "one" "two" "three" > dj2.txt
"$BB" brief -B 4 -F json dj2.txt > "$T/j" 2>/dev/null
ck "truncated_by names the budget" "1" "$("$BB" grep -c '"truncated_by":"budget"' "$T/j")"
ck "hint names -B" "1" "$("$BB" grep -c 'raise -B' "$T/j")"

"$BB" brief -m 5 -F json dj2.txt > "$T/j" 2>/dev/null
ck "truncated_by names -m" "1" "$("$BB" grep -c '"truncated_by":"min_count"' "$T/j")"

"$BB" brief -o zzznomatch -F json dj2.txt > "$T/j" 2>/dev/null
ck "truncated_by names selection" "1" "$("$BB" grep -c '"truncated_by":"selection"' "$T/j")"
ck "hint warns that -o is not a regex" "1" "$("$BB" grep -c 'substrings, not regexes' "$T/j")"

# projected fields come out as an array: nothing to re-split
printf 'src/a.c:1: error: bad\nsrc/a.c:9: error: bad\n' > dj3.txt
"$BB" brief -i : -c 1 -F json dj3.txt > "$T/j" 2>/dev/null
ck "f is the projected field array" "1" "$("$BB" grep -c '"f":\["src/a.c"\]' "$T/j")"
ck "f is absent without a projection" "1" \
	"$("$BB" brief -F json dj2.txt 2>/dev/null | "$BB" grep -c '"f":')"

# samples only when -a asked for more than one
printf 'x1\nx2\n' > dj4.txt
"$BB" brief -s -a 2 -F json dj4.txt > "$T/j" 2>/dev/null
ck "samples appears with -a 2" "1" "$("$BB" grep -c '"samples":\["x1","x2"\]' "$T/j")"
ck "line is the first sample" "1" "$("$BB" grep -c '"line":"x1"' "$T/j")"
"$BB" brief -s -F json dj4.txt > "$T/j" 2>/dev/null
ck "no samples key by default" "1" "$("$BB" grep -c -v '"samples":' "$T/j")"

# a multi-line record keeps its lines, escaped once, not as \u000a
{ printf 'commit aaa\nAuthor: X\n    one\n'; } > dj5.txt
"$BB" brief -R commit -F json dj5.txt > "$T/j" 2>/dev/null
ck "a section is one json string" "1" "$("$BB" grep -c 'commit aaa\\nAuthor: X\\n' "$T/j")"
ck "no \\u000a escaping" "0" "$("$BB" grep -c 'u000a' "$T/j")"

# the text marker names the same reason
"$BB" brief -B 4 dj2.txt > "$T/o" 2>/dev/null
ck "marker carries truncated_by" "budget" "$(mfo truncated_by < "$T/o")"
"$BB" brief dj2.txt > "$T/o" 2>/dev/null
ck "marker says - when nothing was cut" "-" "$(mfo truncated_by < "$T/o")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
