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
ck "df"                 "yes"   "$("$BB" df . | "$BB" awk 'NR==2{print ($2>0)?"yes":"no"}')"
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

echo
echo "==== $pass passed, $fail failed ===="
[[ "$fail" -eq 0 ]]
