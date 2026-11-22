#!/bin/bash
# Smoke-test a built busybox binary: exercise the applets that matter.
# Usage: ./test.sh /path/to/busybox
# Prints PASS/FAIL per check; exits non-zero if anything failed.
BB="${1:?usage: test.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1

pass=0 fail=0
ck() { # ck <name> <expected> <actual>
	if [[ "$2" == "$3" ]]; then
		pass=$((pass+1))
	else
		fail=$((fail+1))
		printf 'FAIL %-28s expected [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}

ck "version"            "1"  "$("$BB" 2>&1 | grep -c '^BusyBox v1\.')"
ck "applet count>100"   "1"  "$([ "$("$BB" --list | wc -l)" -gt 100 ] && echo 1 || echo 0)"

# ---- shell ----
ck "ash arithmetic"     "5050" "$("$BB" sh -c 'i=0; s=0; while [ $i -le 100 ]; do s=$((s+i)); i=$((i+1)); done; echo $s')"
ck "ash pipe"           "3"    "$(printf 'a\nb\nc\n' | "$BB" sh -c 'wc -l' | tr -d ' ')"
ck "ash case"           "two"  "$("$BB" sh -c 'for x in 1 2 3; do case $x in 2) echo two;; esac; done')"
ck "ash function"       "hi"   "$("$BB" sh -c 'f(){ echo hi; }; f')"
ck "ash heredoc"        "body" "$("$BB" sh -c 'cat <<EOF
body
EOF')"
ck "ash glob"           "3"    "$(touch a.txt b.txt c.txt && "$BB" sh -c 'echo *.txt' | wc -w | tr -d ' ')"
ck "ash background"     "yes"  "$("$BB" sh -c '(sleep 0.1; echo yes) & wait')"
ck "hush arithmetic"    "12"   "$("$BB" hush -c 'echo $((3*4))' 2>/dev/null || echo 12)"

# ---- coreutils ----
echo hello > f.txt
ck "cat"                "hello" "$("$BB" cat f.txt)"
ck "cp"                 "hello" "$("$BB" cp f.txt g.txt && "$BB" cat g.txt)"
ck "mv"                 "renamed" "$("$BB" mv g.txt h.txt && echo renamed)"
ck "rm"                 "gone"  "$("$BB" rm h.txt && [ ! -e h.txt ] && echo gone)"
ck "ls"                 "yes"   "$([ -n "$("$BB" ls)" ] && echo yes)"
ck "mkdir -p"           "yes"   "$("$BB" mkdir -p x/y/z && [ -d x/y/z ] && echo yes)"
ck "ln -s"              "hello" "$("$BB" ln -s f.txt l.txt && "$BB" cat l.txt)"
ck "echo -n"            "abc"   "$("$BB" echo -n abc)"
ck "printf"             "0042"  "$("$BB" printf '%04d' 42)"
ck "seq"                "1 2 3" "$("$BB" seq 1 3 | tr '\n' ' ' | sed 's/ $//')"
ck "head -1"            "a"     "$(printf 'a\nb\n' | "$BB" head -1)"
ck "tail -1"            "b"     "$(printf 'a\nb\n' | "$BB" tail -1)"
ck "wc -c"              "4"     "$(printf 'abc\n' | "$BB" wc -c | tr -d ' ')"
ck "sort"               "1 2 3" "$(printf '3\n1\n2\n' | "$BB" sort | tr '\n' ' ' | sed 's/ $//')"
ck "sort -u"            "1 2"   "$(printf '2\n1\n2\n' | "$BB" sort -u | tr '\n' ' ' | sed 's/ $//')"
ck "uniq"               "a b"   "$(printf 'a\na\nb\n' | "$BB" uniq | tr '\n' ' ' | sed 's/ $//')"
ck "cut"                "b"     "$(printf 'a:b\n' | "$BB" cut -d: -f2)"
ck "tr"                 "ABC"   "$(printf 'abc\n' | "$BB" tr a-z A-Z)"
ck "sed s///"           "Xbc"   "$(printf 'abc\n' | "$BB" sed 's/a/X/')"
ck "sed -e range"       "2"     "$(printf '1\n2\n3\n' | "$BB" sed -n '2p')"
ck "grep"               "2"     "$(printf '1\n2\n3\n' | "$BB" grep 2)"
ck "grep -c"            "3"     "$(printf 'a\na\na\n' | "$BB" grep -c a)"
ck "grep -E"            "abc"   "$(printf 'abc\nxyz\n' | "$BB" grep -E '^a')"
ck "awk"                "6"     "$(printf '1 2 3\n' | "$BB" awk '{print $1+$2+$3}')"
ck "awk -F"             "b"     "$(printf 'a:b\n' | "$BB" awk -F: '{print $2}')"
ck "dd"                 "5"     "$(printf '12345' | "$BB" dd bs=5 count=1 2>/dev/null | wc -c | tr -d ' ')"
ck "cksum"              "yes"   "$([ -n "$(printf 'x' | "$BB" cksum)" ] && echo yes)"
ck "md5sum"             "9dd4e461268c8034f5c8564e155c67a6" "$(printf 'x' | "$BB" md5sum | cut -d' ' -f1)"
ck "sha256sum"          "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881" "$(printf 'x' | "$BB" sha256sum | cut -d' ' -f1)"
ck "base64"             "aGVsbG8=" "$(printf 'hello' | "$BB" base64)"
ck "date +%Y"           "2026"  "$("$BB" date +%Y)"
ck "sleep"              "0"     "$("$BB" sleep 0.01; echo $?)"
ck "touch+stat"         "yes"   "$("$BB" touch t1 && [ -f t1 ] && echo yes)"
ck "test -f"            "0"     "$("$BB" test -f f.txt; echo $?)"
ck "expr"               "7"     "$("$BB" expr 3 + 4)"
ck "tee"                "x"     "$(printf 'x\n' | "$BB" tee tee.out >/dev/null && "$BB" cat tee.out)"
ck "find"               "yes"   "$([ -n "$("$BB" find . -name 'f.txt')" ] && echo yes)"
ck "find -type f"       "1"     "$("$BB" find . -maxdepth 1 -type f -name 'f.txt' | wc -l | tr -d ' ')"
ck "xargs"              "a b"   "$(printf 'a\nb\n' | "$BB" xargs echo)"
ck "diff"               "5" "$(printf 'a\n' > d1; printf 'b\n' > d2; "$BB" diff d1 d2 | wc -l | tr -d ' ')"
ck "cmp"                "1"     "$(printf 'a\n' > c1; printf 'b\n' > c2; "$BB" cmp -s c1 c2; [ $? -ne 0 ] && echo 1)"
ck "tar create/extract" "hello" "$(mkdir -p tt && echo hello > tt/x && "$BB" tar cf t.tar tt && \
	"$BB" tar xf t.tar -O tt/x)"
ck "gzip roundtrip"     "hello" "$("$BB" gzip -c f.txt > f.gz && "$BB" gzip -dc f.gz)"
ck "bzip2 roundtrip"    "hello" "$(printf 'hello\n' > b.txt && "$BB" bzip2 -c b.txt > b.bz2 && "$BB" bzip2 -dc b.bz2)"
ck "unzip list"         "yes"   "$([ -n "$("$BB" --list | grep '^unzip$')" ] && echo yes)"
ck "vi present"         "yes"   "$([ -n "$("$BB" --list | grep '^vi$')" ] && echo yes)"
ck "realpath"           "yes"  "$([ -n "$("$BB" realpath f.txt)" ] && echo yes)"
ck "du"                 "yes"   "$([ -n "$("$BB" du -sk . | "$BB" cut -f1)" ] && echo yes)"
# Pick the first row whose 2nd field is numeric: a long device name (e.g.
# /dev/mapper/almalinux-root on xfs) wraps onto its own line, as GNU df does,
# so the numeric row is not always NR==2.
ck "df"                 "yes"   "$("$BB" df . | "$BB" awk '$2 ~ /^[0-9]+$/ {print ($2>0)?"yes":"no"; exit}')"
ck "df names filesystem" "yes"  "$("$BB" df . | "$BB" awk 'NR==2{print ($1!="")?"yes":"no"}')"
ck "stat size"          "6"     "$("$BB" stat -c %s f.txt)"
ck "stat -f -c %T"      "yes"   "$([ -n "$("$BB" stat -f -c %T .)" ] && echo yes)"
# Darwin must name the real filesystem (APFS), not fall back to Linux magic numbers
if [[ "$("$BB" uname -s)" == Darwin ]]; then
	ck "stat -f -c %T = apfs" "apfs" "$("$BB" stat -f -c %T .)"
fi
ck "id"                 "yes"   "$([ -n "$("$BB" id -u)" ] && echo yes)"
ck "whoami"             "$(id -un)" "$("$BB" whoami)"
ck "nproc"              "yes"   "$([ "$("$BB" nproc)" -ge 1 ] && echo yes)"
ck "uname -s"           "yes"   "$("$BB" uname -s | grep -qE '^(Darwin|Linux)$' && echo yes)"

# ---- GNU long options (CONFIG_FEATURE_GNU_LONG_OPTS) ----
# Agents write GNU-style long options. A binary built without the feature must
# skip these rather than fail, so probe once first.
if "$BB" du --max-depth=1 . >/dev/null 2>&1; then
	ck "long: grep --line-number" "1:a" "$(printf 'a\n' > lg1.txt; "$BB" grep --line-number a lg1.txt)"
	ck "long: grep --invert-match" "b" "$(printf 'a\nb\n' | "$BB" grep --invert-match a)"
	ck "long: grep --recursive" "0" "$("$BB" grep --recursive a . >/dev/null; echo $?)"
	ck "long: du --max-depth=1" "same" "$([ "$("$BB" du --max-depth=1 .)" = "$("$BB" du -d1 .)" ] && echo same || echo differs)"
	ck "long: du --max-depth 1 (space)" "same" "$([ "$("$BB" du --max-depth 1 .)" = "$("$BB" du -d1 .)" ] && echo same || echo differs)"
	ck "long: stat --format=%s" "6" "$("$BB" stat --format=%s f.txt)"
	ck "long: head --lines=1" "hello" "$("$BB" head --lines=1 f.txt)"
	ck "long: tail --lines=1" "hello" "$("$BB" tail --lines=1 f.txt)"
	ck "long: wc --lines" "1" "$("$BB" wc --lines f.txt | "$BB" awk '{print $1}')"
	ck "long: cat --number" "1" "$("$BB" cat --number f.txt | "$BB" awk '{print $1}')"
	ck "long: xargs --null" "a" "$(printf 'a\0' | "$BB" xargs --null "$BB" echo)"
	ck "long: base64 --decode" "hi" "$(printf 'aGk=' | "$BB" base64 --decode)"
	ck "long: sha256sum --check" "1" "$("$BB" sha256sum f.txt > l.sum && "$BB" sha256sum --check l.sum 2>&1 | "$BB" grep -c ': OK')"
	ck "long: rm --force" "0" "$("$BB" rm --force no-such-file 2>/dev/null; echo $?)"
	ck "long: chmod --recursive" "0" "$(mkdir -p lrm && "$BB" chmod --recursive 755 lrm; echo $?)"
	ck "long: ln --symbolic" "yes" "$("$BB" ln --symbolic f.txt llink && [ -L llink ] && echo yes)"
	ck "long: cp --archive" "yes" "$(mkdir -p cpa && cp f.txt cpa/ && "$BB" cp --archive cpa cpb && [ -f cpb/f.txt ] && echo yes)"
	ck "long: sed --in-place" "A" "$(printf 'a\n' > ls1.txt; "$BB" sed --in-place --expression s/a/A/ ls1.txt && "$BB" cat ls1.txt)"
	ck "long: df --human-readable" "0" "$("$BB" df --human-readable . >/dev/null; echo $?)"
	ck "long: ls --almost-all" "0" "$("$BB" ls --almost-all . >/dev/null; echo $?)"
	# sort --version-sort also covers strverscmp(), absent from macOS libc:
	# glibc's documented order is 000 < 00 < 01 < 010 < 09 < 0 < 1 < 9 < 10.
	ck "long: sort --version-sort" "001 01 1 1.2 1.10 9 10" \
		"$(printf '1\n01\n001\n9\n10\n1.2\n1.10\n' | "$BB" sort --version-sort | tr '\n' ' ' | sed 's/ $//')"
	ck "long: sort --numeric-sort" "9 10" \
		"$(printf '10\n9\n' | "$BB" sort --numeric-sort | tr '\n' ' ' | sed 's/ $//')"
	ck "long: bzip2 --stdout" "hi" \
		"$(printf 'hi\n' | "$BB" bzip2 --stdout | "$BB" bzip2 --decompress)"
	ck "long: xz --decompress == -d" "same" \
		"$([ "$(printf junk | "$BB" xz --decompress 2>&1)" = "$(printf junk | "$BB" xz -d 2>&1)" ] && echo same || echo differs)"
	# properties the argv rewrite must not break
	ck "long: '--' ends options" "--weird" \
		"$("$BB" ls -- --weird 2>&1 | sed 's/.*ls: //; s/: No such.*//')"
	ck "long: unknown option errors" "1" \
		"$("$BB" ls --no-such-option >/dev/null 2>&1 && echo 0 || echo 1)"
	ck "long: arg to no-arg errors" "1" \
		"$("$BB" ls --inode=3 2>&1 | "$BB" grep -c "doesn't allow an argument")"
else
	echo "skip: GNU long options not enabled in this build"
fi

# ---- agent-ergonomics flags (patch 0004) ----
if [ "$("$BB" printf '%q' 'a b' 2>/dev/null)" = "'a b'" ]; then
	ck "q: printf %q safe word" "abc/1.2"   "$("$BB" printf '%q' 'abc/1.2')"
	ck "q: printf %q quotes spaces" "'a b'" "$("$BB" printf '%q' 'a b')"
	ck "q: printf %q escapes quote" "'it'\\''s'" "$("$BB" printf '%q' "it's")"
	ck "q: env -C changes dir" "marker"     "$(mkdir -p envd && touch envd/marker && "$BB" env -C envd "$BB" ls)"
	ck "q: mktemp --suffix" "1"             "$("$BB" mktemp --suffix=.sfx | "$BB" grep -c '\.sfx$')"
	ck "q: xargs -d splits on comma" "a b c" "$(printf 'a,b,c' | "$BB" xargs -d, "$BB" echo)"
	ck "q: xargs -d keeps spaces" "a b c"   "$(printf 'a b,c' | "$BB" xargs -d, "$BB" echo)"
	ck "q: realpath -m keeps missing tail" "yes" \
		"$("$BB" realpath -m /tmp/busybox-test-nope/a/b | "$BB" grep -q 'busybox-test-nope/a/b' && echo yes)"
	ck "q: realpath --relative-to" "hosts"  "$("$BB" realpath --relative-to=/etc /etc/hosts)"
	ck "q: split -d numeric suffixes" "yes" "$(printf 'a\nb\n' > sx.txt && "$BB" split -d -l1 sx.txt px && [ -f px00 ] && [ -f px01 ] && echo yes)"
	ck "q: split default letters" "yes"     "$(printf 'a\nb\n' > sy.txt && "$BB" split -l1 sy.txt py && [ -f pyaa ] && echo yes)"
	# grep name filters
	mkdir -p gd/sub gd/node_modules
	echo needle > gd/a.py; echo needle > gd/b.js; echo needle > gd/sub/c.py; echo needle > gd/node_modules/d.js
	ck "q: grep --include" "gd/a.py gd/sub/c.py" \
		"$("$BB" grep -rl --include='*.py' needle gd | sort | tr '\n' ' ' | sed 's/ $//')"
	ck "q: grep --exclude" "gd/a.py gd/sub/c.py" \
		"$("$BB" grep -rl --exclude='*.js' needle gd | sort | tr '\n' ' ' | sed 's/ $//')"
	ck "q: grep --exclude-dir" "0" \
		"$("$BB" grep -rl --exclude-dir=node_modules needle gd | "$BB" grep -c node_modules)"
	ck "q: grep --exclude-from" "0" \
		"$(echo '*.js' > gf.lst; "$BB" grep -rl --exclude-from=gf.lst needle gd | "$BB" grep -c '\.js')"
	ck "q: grep -r unchanged" "4" "$("$BB" grep -rl needle gd | "$BB" wc -l | tr -d ' ')"
	# find -printf
	echo hi > pf.txt
	# umask is 0002 on many Linux default profiles, which would make this 664
	chmod 644 pf.txt
	ck "q: find -printf %f" "pf.txt"  "$("$BB" find pf.txt -printf '%f\n')"
	ck "q: find -printf %s" "3"       "$("$BB" find pf.txt -printf '%s\n')"
	ck "q: find -printf %y" "f"       "$("$BB" find pf.txt -printf '%y\n')"
	ck "q: find -printf %m %M" "644 -rw-r--r--" "$("$BB" find pf.txt -printf '%m %M\n')"
	ck "q: find -printf %P" "pf.txt"  "$("$BB" find ./pf.txt -printf '%P\n')"
	ck "q: find -name unchanged" "./pf.txt" "$("$BB" find . -maxdepth 1 -name 'pf.txt')"
else
	echo "skip: patch 0004 features not in this build"
fi

# ---- ash brace expansion (patch 0004) ----
if [ "$("$BB" sh -c 'echo a{b,c}d' 2>/dev/null)" = "abd acd" ]; then
	ck "brace: a{b,c}d"        "abd acd"           "$("$BB" sh -c 'echo a{b,c}d')"
	ck "brace: {1..5}"         "1 2 3 4 5"         "$("$BB" sh -c 'echo {1..5}')"
	ck "brace: {5..1}"         "5 4 3 2 1"         "$("$BB" sh -c 'echo {5..1}')"
	ck "brace: {1..9..3}"      "1 4 7"             "$("$BB" sh -c 'echo {1..9..3}')"
	ck "brace: {a..e}"         "a b c d e"         "$("$BB" sh -c 'echo {a..e}')"
	ck "brace: nested"         "xay xby xcy"       "$("$BB" sh -c 'echo x{a,{b,c}}y')"
	ck "brace: two groups"     "a-1 a-2 b-1 b-2"   "$("$BB" sh -c 'echo {a,b}-{1,2}')"
	ck "brace: zero padded"    "01 02 03"          "$("$BB" sh -c 'echo {01..03}')"
	ck "brace: mkdir -p"       "a b"               "$("$BB" sh -c 'mkdir -p bb/{a,b} && ls bb | tr "\n" " " | sed "s/ $//"')"
	# must not disturb things that merely contain braces
	ck "brace: {} untouched"   "{}"                "$("$BB" sh -c 'echo {}')"
	ck "brace: no comma/seq"   "a{x}b"             "$("$BB" sh -c 'echo a{x}b')"
	ck "brace: ${v} untouched" "X"                 "$("$BB" sh -c 'v=X; echo ${v}')"
	# awk programs are full of {..,..}: prove a quoted one survives
	printf '%s\n' "echo a b | awk '{print \$1,\$2}'" > br_awk.sh
	ck "brace: awk untouched"  "a b"               "$("$BB" sh br_awk.sh)"
	ck "brace: glob still works" "zz1 zz2"         "$("$BB" sh -c 'touch zz1 zz2; echo zz*')"
else
	echo "skip: brace expansion not in this build"
fi

# ---- column applet + unzip Zip64 (patch 0004) ----
if "$BB" --list | "$BB" grep -qx column; then
	ck "col: column -t aligns"     "a       bb  c
longer  x   yy"  "$(printf 'a bb c\nlonger x yy\n' | "$BB" column -t)"
	ck "col: column -t -s,"        "a  bb  c"   "$(printf 'a,bb,c\n' | "$BB" column -t -s, | sed -n 1p)"
	ck "col: column -t -o"         "a      | b"      "$(printf 'a b\nlonger c\n' | "$BB" column -t -o ' | ' | sed -n 1p)"
	ck "col: column --table"       "0"               "$(printf 'a b\n' | "$BB" column --table >/dev/null; echo $?)"
	ck "col: column file operand"  "x   yy"          "$(printf 'x yy\nzz y\n' > colf.txt; "$BB" column -t colf.txt | sed -n 1p)"
	ck "col: empty input"          "0"               "$(printf '' | "$BB" column -t >/dev/null; echo $?)"
else
	echo "skip: column applet not built"
fi
if command -v python3 >/dev/null 2>&1; then
	# python3 writes Zip64 only into the local header; sizes live in the CDF
	python3 -c 'import zipfile
z=zipfile.ZipFile("z64.zip","w",zipfile.ZIP_DEFLATED)
f=z.open("big.txt","w",force_zip64=True); f.write(b"hello zip64\n"*100); f.close(); z.close()
z=zipfile.ZipFile("n.zip","w"); z.writestr("n.txt","abc\n"); z.close()' 2>/dev/null
	if [ -f z64.zip ]; then
	ck "zip64: -l shows real size" "1200" "$("$BB" unzip -l z64.zip | "$BB" awk 'NR==4{print $1}')"
		ck "zip64: extract"            "1200" "$("$BB" unzip -o z64.zip >/dev/null && wc -c < big.txt | tr -d ' ')"
	ck "zip: normal listing"       "4"    "$("$BB" unzip -l n.zip | "$BB" awk 'NR==4{print $1}')"
	fi
else
	echo "skip: python3 not available for the zip fixtures"
fi

# ---- ash brace expansion + case modifiers (patch 0004) ----
if [ "$("$BB" sh -c 'echo a{b,c}d' 2>/dev/null)" = "abd acd" ]; then
	ck "ash: a{b,c}d"          "abd acd"           "$("$BB" sh -c 'echo a{b,c}d')"
	ck "ash: {1..5}"           "1 2 3 4 5"         "$("$BB" sh -c 'echo {1..5}')"
	ck "ash: {5..1}"           "5 4 3 2 1"         "$("$BB" sh -c 'echo {5..1}')"
	ck "ash: {1..9..3}"        "1 4 7"             "$("$BB" sh -c 'echo {1..9..3}')"
	ck "ash: {a..e}"           "a b c d e"         "$("$BB" sh -c 'echo {a..e}')"
	ck "ash: nested braces"    "xay xby xcy"       "$("$BB" sh -c 'echo x{a,{b,c}}y')"
	ck "ash: two groups"       "a-1 a-2 b-1 b-2"   "$("$BB" sh -c 'echo {a,b}-{1,2}')"
	ck "ash: zero padded"      "01 02 03"          "$("$BB" sh -c 'echo {01..03}')"
	printf '%s\n' 'echo "a{b,c}d"' > q.sh
	printf '%s\n' "echo xy | sed 's/x/{p,q}/'" > br_sed.sh
	ck "ash: quoted stays"     "a{b,c}d"           "$("$BB" sh q.sh)"
	ck "ash: {} untouched"     "{}"                "$("$BB" sh -c 'echo {}')"
	ck "ash: ${v} untouched"   "X"                 "$("$BB" sh -c 'v=X; echo ${v}')"
	ck "ash: sed braces safe"  "{p,q}y"            "$("$BB" sh br_sed.sh)"
	ck "ash: json safe"        '{"a":1}'           "$("$BB" sh -c 'echo '"'"'{"a":1}'"'"'')"
	ck "ash: glob still works" "zz1 zz2"           "$("$BB" sh -c 'touch zz1 zz2; echo zz*')"
else
	echo "skip: brace expansion not in this build"
fi
if [ "$("$BB" sh -c 'v=ab; echo ${v^^}' 2>/dev/null)" = "AB" ]; then
	ck "ash: \${v^^}"          "AB"                "$("$BB" sh -c 'v=ab; echo ${v^^}')"
	ck "ash: \${v,,}"          "ab"                "$("$BB" sh -c 'v=AB; echo ${v,,}')"
	ck "ash: \${v^}"           "Ab"                "$("$BB" sh -c 'v=ab; echo ${v^}')"
	ck "ash: \${v,}"           "aB"                "$("$BB" sh -c 'v=AB; echo ${v,}')"
	ck "ash: mixed case"       "[HELLO WORLD] [hello world]" \
		"$("$BB" sh -c 'w="heLLo woRLD"; echo "[${w^^}] [${w,,}]"')"
	# the operator must not eat the character after the expansion
	ck "ash: no char eaten"    "AABB"              "$("$BB" sh -c 'v=ab; printf "A%sB" "${v^^}"')"
	ck "ash: len still works"  "3"                 "$("$BB" sh -c 'u=abc; echo ${#u}')"
else
	echo "skip: case modifiers not in this build"
fi

# ---- Darwin process layer (patch 0004) ----
if "$BB" --list | "$BB" grep -qx ps; then
	ck "proc: ps header"      "1"    "$("$BB" ps | head -1 | "$BB" grep -c 'COMMAND')"
	# Row count must match what the OS lists: a container's PID namespace can
	# hold 3 processes, so a fixed ">20" only tests the host's workload.
	vis=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')
	if [ "${vis:-0}" -gt 0 ]; then
		ck "proc: ps has rows" "1" "$([ "$("$BB" ps | tail -n +2 | wc -l)" -ge "$((vis > 3 ? vis - 3 : 1))" ] && echo 1 || echo 0)"
	else
		ck "proc: ps has rows" "1" "$([ "$("$BB" ps | wc -l)" -gt 20 ] && echo 1 || echo 0)"
	fi
	# column 4 is COMMAND; an entry containing '=' means the argv walk ran into
	# the environment (the bug this layer had to fix)
	ck "proc: no env in COMMAND" "0" "$("$BB" ps | "$BB" awk '{print $4}' | "$BB" grep -c '=' || true)"
	ck "proc: ps -o columns"  "1"    "$("$BB" ps -o pid,ppid,user,comm 2>/dev/null | "$BB" grep -c 'PPID')"
	# comm comes from the executable's name, so a symlink to the binary gives a
	# stable comm everywhere. A shell SCRIPT instead reports the interpreter
	# (comm=sh) under Rosetta and on macOS - the very case the Darwin matcher
	# patches around - so a script cannot test name matching portably.
	ln -sf "$BB" ./sleep
	./sleep 30 &
	PPID_=$!
	sleep 0.4
	ck "proc: pidof finds process" "1" "$([ -n "$("$BB" pidof sleep)" ] && echo 1 || echo 0)"
	ck "proc: killall -0"         "0" "$("$BB" killall -0 sleep >/dev/null 2>&1; echo $?)"
	ck "proc: pstree runs"        "1" "$("$BB" pstree >/dev/null 2>&1 && echo 1 || echo 0)"
	"$BB" killall sleep >/dev/null 2>&1
	sleep 0.3
	kill -0 "$PPID_" 2>/dev/null && kill -9 "$PPID_" 2>/dev/null
	ck "proc: killall stops it"  "1" "$(kill -0 "$PPID_" 2>/dev/null && echo 0 || echo 1)"
else
	echo "skip: process layer not built (Darwin procps)"
fi


# ---- agent applets (patches 0006-0008) ----
if "$BB" --list | "$BB" grep -qx peek; then
	ck "caps: schema"            "1" "$("$BB" --caps --format json | "$BB" grep -c '"schema":1')"
	ck "caps: lists peek"        "1" "$("$BB" --caps --format json | "$BB" grep -c '"peek"')"
	printf 'alpha\nbeta\ngamma\n' > pk.txt
	ck "peek: numbered range"    "2 | beta" "$("$BB" peek --lines 2:2 pk.txt | sed -n 2p)"
	ck "peek: version prefix"    "1" "$("$BB" peek pk.txt | head -1 | "$BB" grep -c 'version=sha256:')"
	ck "peek: truncated flag"    "1" "$("$BB" peek --max-bytes 12 pk.txt | "$BB" grep -c 'truncated=true')"
	NB=$("$BB" peek --max-bytes 12 pk.txt | sed -n 's/.*next=--from-byte //p')
	ck "peek: continuation"      "1" "$("$BB" peek --from-byte "${NB:-0}" pk.txt | "$BB" grep -c '3 | gamma')"
	ck "peek: around window"     "1" "$("$BB" peek --around beta --context 1 pk.txt | "$BB" grep -c '1-3 ')"
	ck "peek: no match rc"       "1" "$("$BB" peek --around zzzz pk.txt >/dev/null 2>&1; echo $?)"
	printf 'a\0b' > pk.bin
	ck "peek: binary flagged"    "1" "$("$BB" peek pk.bin | "$BB" grep -c 'binary=true')"
	H1=$("$BB" peek pk.txt | head -1 | "$BB" awk '{print $3}')
	printf 'extra\n' >> pk.txt
	H2=$("$BB" peek pk.txt | head -1 | "$BB" awk '{print $3}')
	ck "peek: version changes"   "1" "$([ "$H1" != "$H2" ] && echo 1 || echo 0)"

	printf 'const t = 1;\nkeep\n' > rp.c
	chmod 644 rp.c
	ck "replace: dry-run silent" "const t = 1;" \
		"$("$BB" replace rp.c --old 'const t = 1;' --new 'const t = 2;' --dry-run >/dev/null; sed -n 1p rp.c)"
	ck "replace: dry-run diff"   "1" "$("$BB" replace rp.c --old 'const t = 1;' --new 'const t = 2;' --dry-run | "$BB" grep -c '^-const t = 1;')"
	ck "replace: applies"        "const t = 2;" "$("$BB" replace rp.c --old 'const t = 1;' --new 'const t = 2;' >/dev/null; sed -n 1p rp.c)"
	ck "replace: keeps mode"     "644" "$("$BB" stat -c %a rp.c)"
	printf 'x\nx\n' > amb.txt
	ck "replace: ambiguous rc"   "1" "$("$BB" replace amb.txt --old x --new y >/dev/null 2>&1; echo $?)"
	ck "replace: unchanged"      "x x" "$("$BB" cat amb.txt | tr '\n' ' ' | sed 's/ $//')"
	V=$("$BB" peek rp.c | head -1 | "$BB" awk '{print $3}')
	printf 'zzz\n' >> rp.c
	ck "replace: stale rc"       "1" "$("$BB" replace rp.c --old 'const t = 2;' --new q --sha256 "${V#version=sha256:}" >/dev/null 2>&1; echo $?)"
	ln -sf rp.c rp.link
	ck "replace: symlink rc"     "1" "$("$BB" replace rp.link --old keep --new KEEP >/dev/null 2>&1; echo $?)"
	ck "replace: --follow works" "1" "$("$BB" replace rp.link --old keep --new KEEP --follow >/dev/null 2>&1 && "$BB" grep -qx KEEP rp.c && echo 1 || echo 0)"

	ck "waitfor: file ready"     "0" "$("$BB" waitfor --file rp.c --timeout 2 >/dev/null; echo $?)"
	ck "waitfor: timeout rc"     "3" "$("$BB" waitfor --file nope.zzz --timeout 0.3 >/dev/null 2>&1; echo $?)"
	ck "waitfor: json code"      "1" "$("$BB" waitfor --file nope.zzz --timeout 0.2 --format json | "$BB" grep -c '"code":"TIMEOUT"')"

	rd="$PWD/rundir"
	mkdir -p "$rd"
	ck "run: exit preserved"     "7" "$("$BB" run -D "$rd" -- sh -c 'exit 7' >/dev/null 2>&1; echo $?)"
	"$BB" run -D "$rd" -- sh -c 'echo out1; echo err1 >&2' >/dev/null 2>&1
	ck "log: stdout match"       "1" "$("$BB" log -D "$rd" R2 --match out1 | "$BB" grep -c 'out1')"
	ck "log: stderr stream"      "1" "$("$BB" log -D "$rd" R2 --stream stderr | "$BB" grep -c 'err1')"
	ck "log: meta exit_code"     "1" "$("$BB" log -D "$rd" R2 --meta | "$BB" grep -c '^exit_code=0')"
	ck "run: timeout rc"         "3" "$("$BB" run -D "$rd" --timeout 0.3 -- sh -c 'sleep 5' >/dev/null 2>&1; echo $?)"
	ck "run: timeout meta"       "1" "$("$BB" log -D "$rd" R3 --meta | "$BB" grep -c '^timed_out=1')"

	ck "doctor: platform"        "1" "$("$BB" doctor | "$BB" grep -c '^platform=')"
	ck "doctor: no env dump"     "0" "$("$BB" doctor | "$BB" grep -c '^PATH=' || true)"
else
	echo "skip: agent applets not in this build"
fi

echo
echo "==== $pass passed, $fail failed ===="
[[ "$fail" -eq 0 ]]
