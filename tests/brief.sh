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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
