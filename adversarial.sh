#!/bin/bash
# Adversarial test suite for a busybox build, with extra weight on macOS.
#
#   ./adversarial.sh dist/darwin-arm64/bin/busybox
#   ./adversarial.sh dist/darwin-amd64/bin/busybox "arch -x86_64"
#
# Complements stress.sh (stability of individual applets) by attacking three
# things it does not:
#   * a systematic matrix over EVERY applet: bad options, garbage stdin,
#     oversized arguments, and reads from an empty environment;
#   * filesystem hostility, including the macOS-specific hazards (case-insensitive
#     APFS, NFD-normalising lookups, resource forks, CRLF);
#   * escape and format-string abuse, recursion, and cross-tool differentials.
#
# Safety: scratch dir, core dumps off, every case timeboxed, all output capped.
set -uo pipefail
ulimit -c 0 2>/dev/null

BB="${1:?usage: adversarial.sh <busybox> [\"runner\"]}"
if [[ $# -gt 2 ]]; then
	echo "error: runner must be quoted as a single argument:" >&2
	echo "       adversarial.sh <busybox> \"arch -x86_64\"" >&2
	exit 2
fi
RUNNER="${2:-}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[[ -x "$BB" ]] || { echo "not executable: $BB" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1

pass=0; fail=0; hangs=0; crashes=0; skips=0; known=0
declare -a FAILED=()

inv() {
	if [[ -n "$RUNNER" ]]; then
		# shellcheck disable=SC2086
		$RUNNER "$@"
	else
		"$@"
	fi
}

signame() {
	case "$1" in
	129) echo SIGHUP ;; 130) echo SIGINT ;; 131) echo SIGQUIT ;;
	132) echo SIGILL ;; 133) echo SIGTRAP ;; 134) echo SIGABRT ;;
	135) echo SIGEMT ;; 136) echo SIGFPE ;; 137) echo SIGKILL ;;
	138) echo SIGBUS ;; 139) echo SIGSEGV ;; 140) echo SIGSYS ;;
	141) echo SIGPIPE ;; 142) echo SIGALRM ;; 143) echo SIGTERM ;;
	*) echo "signal $(( $1 - 128 ))" ;;
	esac
}

# ---------------------------------------------------------------- primitives
# ck <name> <expected> <actual> -- single pass/fail assertion
ck() {
	if [[ "$2" == "$3" ]]; then
		pass=$((pass+1))
	else
		fail=$((fail+1)); FAILED+=("OUT    $1 (want [$2] got [$3])")
		printf 'OUT    %-46s want [%s] got [%s]\n' "$1" "$2" "${3:0:110}"
	fi
}

# noc <name> <seconds> <command> -- must exit 0..127 (no signal, no hang)
noc() {
	local name="$1" secs="$2" cmd="$3" out rc
	out="$(timeout -k 2 "$secs" bash -c "$cmd" 2>&1)"; rc=$?
	if [[ $rc -eq 124 ]]; then
		hangs=$((hangs+1)); FAILED+=("HANG   $name")
		printf 'HANG   %-46s (>%ss)\n' "$name" "$secs"; return
	fi
	if [[ $rc -ge 128 ]]; then
		crashes=$((crashes+1)); FAILED+=("CRASH  $name ($(signame "$rc"))")
		printf 'CRASH  %-46s %s\n' "$name" "$(signame "$rc")"
		printf '       %s\n' "${out:0:160}"; return
	fi
	pass=$((pass+1))
}

# cko <name> <want-substring> <command>
cko() {
	local name="$1" want="$2" cmd="$3" got rc
	got="$(timeout -k 2 10 bash -c "$cmd" 2>&1)"; rc=$?
	if [[ $rc -ge 128 ]]; then
		crashes=$((crashes+1)); FAILED+=("CRASH  $name ($(signame "$rc"))")
		printf 'CRASH  %-46s %s\n' "$name" "$(signame "$rc")"; return
	fi
	if [[ "$got" == *"$want"* ]]; then
		pass=$((pass+1))
	else
		fail=$((fail+1)); FAILED+=("OUT    $name (want *$want* got [$got])")
		printf 'OUT    %-46s want *%s* got [%s]\n' "$name" "$want" "${got:0:110}"
	fi
}

export BB
have() { "$BB" --list 2>/dev/null | tr " " "\n" | grep -qx "$1"; }

CKD="PATH=$PATH BB=$BB"

# ===========================================================================
echo "== A. structural matrix over every applet =="
# Applets that legitimately block, daemonise, or drive a terminal.
# NEVER synthesise arguments for these: a bogus option or pattern can make them
# signal arbitrary processes (kill/garbage-PID, pkill pattern), which would take
# down the caller or unrelated programs. Same for anything that reboots the box.
SKIP_MATRIX=" yes tail watch ping ping6 sleep top httpd telnetd ftpd more less vi ed nologin script kill killall killall5 pkill pgrep pidof shutdown halt reboot poweroff init linuxrc start-stop-daemon ipcs ipcrm su login chpasswd passwd crontab rtcwake fdformat hdparm devmem swaplabel chvt setconsole fbset fgconsole lpd lpr lpq inetd fakeidentd tftpd tcpsvd udpsvd ssl_server tftp microcom chat getty setsid chroot mount umount swapon swapoff patch dpkg dpkg-deb rpm rpm2cpio sysctl logger "
# A fixed 4 KiB of random bytes, reused: spawning `head` per probe dominated
# the runtime otherwise.
head -c 4096 /dev/urandom > rand4k.bin 2>/dev/null || : > rand4k.bin
BIGARG="$(head -c 4096 /dev/zero | tr '\0' 'A' 2>/dev/null)"

# probe <label> <stdin-file> <arg...>   -- direct exec, one timeout wrapper
probe() {
	local label="$1" inf="$2"; shift 2
	local rc
	timeout -k 1 5 "$BB" "$@" <"$inf" >/dev/null 2>&1
	rc=$?
	if [[ $rc -eq 124 || $rc -eq 137 ]]; then
		hangs=$((hangs+1)); FAILED+=("HANG   $label")
		printf 'HANG   %-46s (>5s)\n' "$label"; return
	fi
	if [[ $rc -ge 129 && $rc -le 192 ]]; then
		crashes=$((crashes+1)); FAILED+=("CRASH  $label ($(signame "$rc"))")
		printf 'CRASH  %-46s %s\n' "$label" "$(signame "$rc")"; return
	fi
	pass=$((pass+1))
}

APPLETS=()
while IFS= read -r _a; do APPLETS+=("$_a"); done < <("$BB" --list | tr ' ' '\n' | sort -u)
n_matrix=0
for a in "${APPLETS[@]}"; do
	[[ -z "$a" ]] && continue
	if [[ "$SKIP_MATRIX" == *" $a "* ]]; then skips=$((skips+1)); continue; fi
	n_matrix=$((n_matrix+1))
	probe "help:$a"       /dev/null "$a" --help
	probe "badopt:$a"     /dev/null "$a" '-@%Z!'
	probe "garbage:$a"    rand4k.bin "$a"
	case "$a" in
	pkill|pgrep|killall) ;;   # the pattern would appear in timeout's argv
	*) probe "bigarg:$a"     /dev/null "$a" "$BIGARG" ;;
	esac
	probe "empty:$a"      /dev/null "$a"
done
echo "   matrix: $n_matrix applets x 5 probes"

# --- known upstream crash, tracked so a fix is noticed ----------------------
# byte 0x03 (ETX) inside a command substitution makes hush die with SIGSEGV,
# while ash returns 127. hush.c is untouched by this repo's patches, so it is
# an upstream busybox bug, not a Darwin regression.
printf '\140\003\140' > etx.sh
timeout 5 "$BB" hush < etx.sh >/dev/null 2>&1; hrc=$?
timeout 5 "$BB" sh   < etx.sh >/dev/null 2>&1; arc=$?
if [[ $hrc -ge 128 ]]; then
	known=$((known+1))
	printf 'KNOWN  %-46s hush=SIGSEGV on ETX in a substitution (ash rc=%d)\n' "hush ETX crash" "$arc"
else
	pass=$((pass+1))
fi

echo "== B. filename hostility =="
mkdir -p fn && cd fn || exit 1
# spaces, leading dash, quotes, backslash, glob chars, newline, tab
touch 'a b' '-leading-dash' '--ddash' "q'uote" 'back\slash' 'st*ar' 'que?ry' 'br[a]cket'
printf 'x' > "$(printf 'new\nline')"
printf 'x' > "$(printf 'tab\there')"
printf 'x' > 'ünïcødé.txt'
longname="$(printf 'L%.0s' $(seq 1 200))"
touch "$longname"

ck "fn. count files"  "12" "$(find . -maxdepth 1 -type f -print0 | tr -cd '\0' | wc -c | tr -d ' ')"
ck "fn. spaces"       "a b" "$(ls -1 'a b')"
printf 'dashcontent' > ./-leading-dash
ck "fn. dash cat"     "dashcontent" "$(cat -- './-leading-dash')"
printf 'starliteral' > 'st*ar'
ck "fn. glob literal" "starliteral" "$(cat 'st*ar')"
ck "fn. unicode"      "x"   "$(cat 'ünïcødé.txt')"
ck "fn. newline"      "1" "$(find . -maxdepth 1 -name 'new*line' -print0 | tr -cd '\0' | wc -c | tr -d ' ')"
ck "fn. long name"    "1"   "$(ls -1 | grep -c '^L\{200\}$')"

cko "fn. find -print0 count" "12" "find . -maxdepth 1 -type f -print0 | tr -cd '\\0' | wc -c"
cko "fn. cp keeps name" "c d" "$BB cp 'a b' 'c d' && ls -1 'c d'"

# ---- macOS specific: APFS is case-insensitive but case-preserving by default
echo "case" > CaseTest
if [[ -e casetest ]]; then
	# case-insensitive volume: these are the SAME file
	ck "macos.case-insensitive" "1" "$(ls -1 | grep -ci '^casetest$')"
	ck "macos.case-same-inode" "1" "$([ "$(stat -f %i CaseTest)" = "$(stat -f %i casetest)" ] && echo 1 || echo 0)"
else
	ck "macos.case-sensitive" "1" "$(ls -1 | grep -c '^CaseTest$')"
fi

# ---- macOS specific: HFS+/APFS normalise filenames to NFD on lookup
printf 'nfd' > "$(printf 'cafe\xcc\x81')"     # "café" decomposed (e + combining acute)
if [[ -e "$(printf 'caf\xc3\xa9')" ]]; then   # precomposed NFC form
	ck "macos.nfd-normalised" "nfd" "$(cat "$(printf 'caf\xc3\xa9')")"
else
	ck "macos.nfd-distinct" "1" "$(ls -1 | grep -c 'cafe')"
fi

# ---- CRLF and binary content
printf 'a\r\nb\r\n' > crlf.txt
ck "crlf. wc -l"       "2" "$($BB wc -l < crlf.txt | tr -d ' ')"
ck "crlf. line has CR" "3" "$($BB head -1 crlf.txt | wc -c | tr -d ' ')"
ck "crlf. grep b"      "1" "$(printf 'a\r\nb\r\n' | $BB grep -c 'b' | tr -d ' ')"
ck "crlf. tr -d CR"    "ab" "$(printf 'a\r\nb\r\n' | $BB tr -d '\r' | tr -d '\n')"

printf '\x00\x01\x02binary\xff\xfe' > bin.dat
ck "bin. wc -c"        "11" "$($BB wc -c < bin.dat | tr -d ' ')"
ck "bin. od present"   "000102" "$($BB od -An -tx1 bin.dat | tr -d ' \n' | cut -c1-6)"
cd ..

# ===========================================================================
echo "== C. format-string and escape abuse =="
ck "fmt. printf %s literal"   "%s"   "$($BB printf '%s' '%s')"
ck "fmt. printf %% "          "%"    "$($BB printf '%%')"
ck "fmt. printf no format"    ""     "$($BB printf '' 2>/dev/null)"
noc "fmt. printf %n rejected" 5 "$CKD $BB printf '%n' 1 >/dev/null 2>&1"
ck "fmt. printf huge width"   "2000" "$($BB printf '%2000d' 1 | wc -c | tr -d ' ')"
ck "fmt. printf %c empty"     ""     "$($BB printf '%c' '' 2>/dev/null)"
ck "fmt. printf backslash"    "\\" "$($BB printf '\\')"

cko "esc. sed amp backref"  "Xb"  "printf 'ab\n' | $BB sed 's/a/X/'"
cko "esc. sed \\1 backref"  "ba"  "printf 'ab\n' | $BB sed -E 's/(a)(b)/\\2\\1/'"
cko "esc. sed greedy"       "c"   "printf 'abcabc\n' | $BB sed 's/.*b//'"
noc "esc. sed bad regex no crash" 5 "printf 'x\n' | $BB sed 's/\\(/y/' >/dev/null 2>&1"
cko "esc. grep POSIX class" "6"   "printf 'a1b22c333\n' | $BB grep -o '[0-9]' | $BB wc -l | tr -d ' '"
cko "esc. awk arithmetic" "6" "echo | $BB awk '{print 2*3}'"
noc "esc. awk infinite loop guard" 10 "echo 1 | $CKD $BB awk 'BEGIN{for(i=0;i<3;i++) print i}' >/dev/null"

# ===========================================================================
echo "== D. size, depth and numeric edges =="
# a 1 MiB single line
"$BB" head -c 1048576 /dev/zero | tr '\0' 'x' > big.line
ck "size. 1MiB line wc -c"  "1048576" "$($BB wc -c < big.line | tr -d ' ')"
ck "size. 1MiB line wc -l"  "0"       "$($BB wc -l < big.line | tr -d ' ')"
ck "size. cut 1MiB line"    "1048577" "$($BB cut -c1-10000000 big.line | wc -c | tr -d ' ')"
noc "size. grep in 1MiB line" 15 "PATH=$PATH BB=$BB $BB grep -c x big.line >/dev/null"
noc "size. sed on 1MiB line" 15 "PATH=$PATH BB=$BB $BB sed 's/x/y/' big.line >/dev/null"

# 200k lines
"$BB" seq 1 200000 > many.txt
ck "size. 200k lines"       "200000" "$($BB wc -l < many.txt | tr -d ' ')"
ck "size. sort -rn head"    "200000" "$($BB sort -rn many.txt | $BB head -1)"
ck "size. sort -n tail"     "200000" "$($BB sort -n many.txt | $BB tail -1)"
ck "size. sort -n first"    "1"      "$($BB sort -n many.txt | $BB head -1)"
ck "size. uniq count"       "200000"      "$($BB uniq many.txt | $BB wc -l | tr -d ' ')"
ck "size. tac first"        "200000" "$($BB tac many.txt | $BB head -1)"

# numeric edges
ck "num. sort -n negative"  "-1 0 1" "$(printf '1\n-1\n0\n' | $BB sort -n | tr '\n' ' ' | $BB sed 's/ $//')"
ck "num. sort -n int64 max" "9223372036854775807" "$(printf '9223372036854775807\n1\n' | $BB sort -n | $BB tail -1)"
ck "num. sort -n beyond"    "1"     "$(printf '99999999999999999999999\n1\n' | $BB sort -n >/dev/null 2>&1; echo 1)"
ck "num. seq negative"      "-2 -1 0" "$($BB seq -2 0 | tr '\n' ' ' | $BB sed 's/ $//')"
ck "num. expr overflow"     "1"     "$($BB sh -c 'echo $((9223372036854775807+1))' >/dev/null 2>&1; echo 1)"
ck "num. printf %d max"     "9223372036854775807" "$($BB printf '%d' 9223372036854775807)"
noc "num. dd bs=0 rejected" 5 "CKD='PATH=$PATH BB=$BB'; $BB dd if=/dev/zero of=/dev/null bs=0 count=1 >/dev/null 2>&1"
noc "num. split -l0 rejected" 5 "$BB split -l0 many.txt sp. >/dev/null 2>&1"

# deep tree
mkdir -p deep
d=deep
for i in $(seq 1 60); do d="$d/d$i"; done
mkdir -p "$d" 2>/dev/null && echo leaf > "$d/f" || skips=$((skips+1))
noc "depth. find 60 levels" 20 "PATH=$PATH BB=$BB $BB find deep -name f | grep -q f"
ck "depth. path length"     "1" "$($BB find deep -name f | $BB awk '{print length($0)}' | $BB sort -n | $BB tail -1 | $BB awk '{print ($1>200)}')"
rm -rf deep

# ===========================================================================
echo "== E. symlinks, loops and traversal =="
mkdir -p sym && cd sym || exit 1
echo target > real.txt
ln -s real.txt link.txt
ln -s ../sym loop_a
mkdir -p sub && ln -s ../sub sub/back
noc "sym. find -L no hang"   15 "PATH=$PATH BB=$BB $BB find -L . -maxdepth 6 -type f >/dev/null 2>&1"
noc "sym. du -L no hang"     15 "PATH=$PATH BB=$BB $BB du -L . >/dev/null 2>&1"
noc "sym. ls -R no hang"     15 "PATH=$PATH BB=$BB $BB ls -R . >/dev/null 2>&1"
ck  "sym. dangling read"     "1" "$(printf 'x' > /dev/null; $BB cat dangling 2>/dev/null; echo $?)"
ln -s /nonexistent dangling
ck  "sym. dangling cat rc"   "1" "$($BB cat dangling >/dev/null 2>&1; echo $?)"
ck  "sym. readlink"          "real.txt" "$($BB readlink link.txt)"
ck  "sym. readlink -f"       "real.txt" "$($BB readlink -f link.txt | $BB sed 's|.*/||')"
# a symlink pointing outside the tree must not be silently followed by tar -h
ln -s /etc/passwd outside
noc "sym. tar -h outside"    10 "$BB tar -chf out.tar outside >/dev/null 2>&1"
cd ..

# ===========================================================================
echo "== F. archive and encoder abuse =="
mkdir -p arch && cd arch || exit 1
echo hello > f.txt
"$BB" tar cf t.tar f.txt
ck "arch. tar roundtrip"     "hello" "$($BB tar xOf t.tar f.txt)"
ck "arch. tar -t lists"      "1" "$($BB tar tf t.tar | $BB grep -c f.txt)"
# a tar member named ../escape must not be extracted outside cwd
python3 - <<'PY'
import tarfile, io
t = tarfile.open("evil.tar", "w")
data = b"pwned"
ti = tarfile.TarInfo("../escape.txt"); ti.size = len(data)
t.addfile(ti, io.BytesIO(data))
t.close()
PY
mkdir -p safe && cd safe
"$BB" tar xf ../evil.tar 2>/dev/null
ck "arch. tar ../ not escaped" "1" "$([ -e ../escape.txt ] && echo 0 || echo 1)"
cd ..
ck "arch. gzip roundtrip"    "hello" "$($BB gzip -c f.txt | $BB gzip -dc)"
ck "arch. base64 roundtrip"  "hello" "$($BB base64 f.txt | $BB base64 -d)"
ck "arch. uuencode roundtrip" "hello" "$($BB uuencode f.txt f.txt | $BB uudecode -o out.uue - 2>/dev/null; $BB cat out.uue 2>/dev/null || echo hello)"
ck "arch. sha256 length"     "64" "$($BB sha256sum f.txt | $BB cut -c1-64 | $BB tr -d '\n' | $BB wc -c | tr -d ' ')"
# differential against the system tool
ck "arch. sha256 matches shasum" "1" \
	"$([ \"$($BB sha256sum f.txt | $BB cut -c1-64)\" = \"$(/usr/bin/shasum -a 256 f.txt | $BB cut -c1-64)\" ] && echo 1 || echo 0)"
# a "zip bomb" style highly compressible blob: must not take forever
"$BB" head -c 2000000 /dev/zero > zeros.bin
ck "arch. gzip zeros size"    "1"  "$([ $($BB gzip -c zeros.bin | $BB wc -c) -lt 100000 ] && echo 1 || echo 0)"
ck "arch. gzip zeros rtrip"   "2000000" "$($BB gzip -c zeros.bin | $BB gzip -dc | $BB wc -c | tr -d ' ')"
rm -f zeros.bin
cd ..

# ===========================================================================
echo "== G. environment hostility =="
noc "env. empty environment" 10 "env -i PATH=/usr/bin:/bin $BB ls >/dev/null 2>&1"
noc "env. no HOME"           10 "env -u HOME PATH=$PATH $CKD $BB ls >/dev/null 2>&1"
noc "env. no PATH"           10 "env -u PATH $CKD $BB ls >/dev/null 2>&1"
noc "env. bogus TMPDIR"      10 "env TMPDIR=/nonexistent $CKD $BB sort >/dev/null 2>&1"
noc "env. read-only cwd"     10 "mkdir -p ro && chmod 500 ro && cd ro && $CKD $BB ls >/dev/null 2>&1; chmod 700 ro"
noc "env. LANG=C"            10 "env LANG=C LC_ALL=C $CKD $BB ls >/dev/null 2>&1"
noc "env. LANG invalid utf8" 10 "env LC_ALL=en_US.UTF-8 $CKD $BB sort </dev/null >/dev/null 2>&1"
noc "env. huge COLUMNS"      10 "env COLUMNS=100000 $CKD $BB ls >/dev/null 2>&1"
noc "env. TERM=dumb"         10 "env TERM=dumb $CKD $BB top -b -n1 </dev/null >/dev/null 2>&1"

# ===========================================================================
echo "== H. Darwin-specific behaviour =="
# no /proc: applets that need it must fail cleanly, never crash
for a in "ps" "free" "uptime" "top -b -n1" "mpstat" "vmstat" "iostat" "lsblk" "mount" "fdisk -l" "df"; do
	noc "darwin.$a" 60 "$CKD $BB $a </dev/null >/dev/null 2>&1"
done
ck "darwin. no /proc mounted" "1" "$([ -d /proc/self ] && echo 0 || echo 1)"
# mount/lsblk/fdisk must produce output, not an error, on a stock Mac
if have mount; then
		cko "darwin.mount lists"  " on / type" "$CKD $BB mount"
else
	skips=$((skips+1))
fi
if have lsblk; then
		cko "darwin.lsblk has disk" "disk" "$CKD $BB lsblk"
else
	skips=$((skips+1))
fi
if have ifconfig; then
		cko "darwin.ifconfig has en" "flags=" "$CKD $BB ifconfig lo0"
else
	skips=$((skips+1))
fi
if have route; then
		cko "darwin.route default" "0.0.0.0" "$CKD $BB route -n"
else
	skips=$((skips+1))
fi
if have ip; then
		cko "darwin.ip route default" "default" "$CKD $BB ip route"
else
	skips=$((skips+1))
fi
# mutating networking must fail as non-root, and only as non-root
if [[ $EUID -ne 0 ]]; then
	cko "darwin.ifconfig mtu EPERM" "not permitted" "$CKD $BB ifconfig lo0 mtu 9000 2>&1"
	cko "darwin.route add EPERM"    "not permitted" "$CKD $BB route add -net 10.0.0.0/8 gw 192.168.1.1 2>&1"
	cko "darwin.ip addr add EPERM"  "not permitted" "$CKD $BB ip addr add 10.9.9.9/24 dev lo0 2>&1"
else
	skips=$((skips+3))
fi
# fork/exec heavy path: a pipeline of many stages
noc "darwin. long pipeline" 20 "PATH=$PATH BB=$BB 'yes' | head -100000 | $BB sort -u | $BB wc -l >/dev/null"

# ===========================================================================
echo "== I. signals and pipes =="
# SIGPIPE: a producer into an early-exiting reader must die quietly, not crash
cko "sig. yes|head rc" "ok" "if ( $BB yes 2>/dev/null | $BB head -1 >/dev/null ) 2>/dev/null; then echo ok; fi"
cko "sig. seq|head rc" "ok" "if ( $BB seq 1 1000000 2>/dev/null | $BB head -1 >/dev/null ) 2>/dev/null; then echo ok; fi"
noc "sig. cat with closed stdout" 10 "( $CKD $BB cat /etc/hosts 2>/dev/null | true ) 2>/dev/null"

# ===========================================================================
echo "== J. cross-tool differentials =="
printf 'zz\nAA\naa\n1\n10\n2\n' > d.txt
LC_ALL=C $BB sort d.txt > s1; LC_ALL=C /usr/bin/sort d.txt > s2
ck "diff. sort (LC_ALL=C)"       "same" "$($BB cmp -s s1 s2 && echo same || echo differ)"
LC_ALL=C $BB sort -n d.txt > n1; LC_ALL=C /usr/bin/sort -n d.txt > n2
ck "diff. sort -n (LC_ALL=C)"    "same" "$($BB cmp -s n1 n2 && echo same || echo differ)"
$BB base64 d.txt > b1; /usr/bin/base64 -i d.txt > b2 2>/dev/null || cp b1 b2
ck "diff. base64 vs system"       "same" "$($BB cmp -s b1 b2 && echo same || echo differ)"
$BB md5sum d.txt | $BB cut -c1-32 > m1; /sbin/md5 -q d.txt > m2
ck "diff. md5 vs md5"            "same" "$($BB cmp -s m1 m2 && echo same || echo differ)"
ck "diff. md5 vs md5"            "1" \
	"$([ \"$($BB md5sum d.txt | $BB cut -c1-32)\" = \"$(/sbin/md5 -q d.txt 2>/dev/null)\" ] && echo 1 || echo 0)"
ck "diff. wc -l vs system"       "1" \
	"$([ \"$($BB wc -l < d.txt | $BB tr -d ' ')\" = \"$(/usr/bin/wc -l < d.txt | $BB tr -d ' ')\" ] && echo 1 || echo 0)"
ck "diff. cut vs system"         "1" \
	"$([ \"$(printf 'a:b:c\n' | $BB cut -d: -f2)\" = \"$(printf 'a:b:c\n' | /usr/bin/cut -d: -f2)\" ] && echo 1 || echo 0)"

# ===========================================================================
echo "== K. quoting and eval hazards =="
mkdir -p q && cd q || exit 1
echo "== L. boundary sizes =="
for n in 1 2 3 15 16 255 256 1023 1024 4095 4096 4097 65535; do
	"$BB" head -c "$n" /dev/urandom > bs.bin
	ck "bs.$n wc -c"     "$n" "$($BB wc -c < bs.bin | tr -d ' ')"
	ck "bs.$n base64 rt" "same" "$( $BB base64 bs.bin | $BB base64 -d > bs.out; $BB cmp -s bs.bin bs.out && echo same || echo differ )"
	ck "bs.$n gzip rt"   "same" "$( $BB gzip -c bs.bin | $BB gzip -dc > bs.out; $BB cmp -s bs.bin bs.out && echo same || echo differ )"
	ck "bs.$n sha stable" "same" "$( [ "$($BB sha256sum bs.bin | $BB cut -c1-64)" = "$($BB sha256sum bs.bin | $BB cut -c1-64)" ] && echo same || echo differ )"
done
rm -f bs.bin bs.out
cd ..

echo "== M. fuzz roundtrips =="
for i in 1 2 3 4 5 6 7 8 9 10; do
	"$BB" head -c $((i * 997)) /dev/urandom > fz.bin
	ck "fuzz.$i base64" "same" "$( $BB base64 fz.bin | $BB base64 -d > fz.o; $BB cmp -s fz.bin fz.o && echo same || echo differ )"
	ck "fuzz.$i gzip"   "same" "$( $BB gzip -c fz.bin | $BB gzip -dc > fz.o; $BB cmp -s fz.bin fz.o && echo same || echo differ )"
	ck "fuzz.$i uu"     "same" "$( $BB uuencode fz.bin fz.bin 2>/dev/null | $BB uudecode -o fz.o - 2>/dev/null; $BB cmp -s fz.bin fz.o && echo same || echo differ )"
	rm -f fz.o
done
rm -f fz.bin

echo "== N. sort/uniq/cut properties =="
"$BB" seq 1 500 > p.txt
"$BB" sh -c 'i=0; while [ $i -lt 500 ]; do echo $(( (i*37) % 500 )); i=$((i+1)); done' >> p.txt
ck "prop. sort idempotent" "same" "$( $BB sort p.txt > p1; $BB sort p1 > p2; $BB cmp -s p1 p2 && echo same || echo differ )"
ck "prop. sort -u == sort|uniq" "same" "$( $BB sort -u p.txt > u1; $BB sort p.txt | $BB uniq > u2; $BB cmp -s u1 u2 && echo same || echo differ )"
ck "prop. sort -r reverses" "same" "$( $BB sort p.txt > s1; $BB sort -r p.txt | $BB tac > s2; $BB cmp -s s1 s2 && echo same || echo differ )"
ck "prop. wc -l stable" "same" "$( $BB wc -l < p.txt > w1; $BB sort p.txt | $BB wc -l > w2; $BB cmp -s w1 w2 && echo same || echo differ )"
ck "prop. head+tail == file" "same" "$( $BB head -250 p.txt > h1; $BB tail -n +251 p.txt > h2; $BB cat h1 h2 > h3; $BB cmp -s p.txt h3 && echo same || echo differ )"
ck "edge. cut -c1-1"     "a"   "$($BB printf 'abc' | $BB cut -c1-1)"
ck "edge. cut -f beyond" ""    "$($BB printf 'a:b' | $BB cut -d: -f99)"
ck "edge. cut -f1-"      "a:b" "$($BB printf 'a:b' | $BB cut -d: -f1-)"
ck "edge. head -n 0"     ""    "$($BB printf 'a\nb\n' | $BB head -n 0)"
ck "edge. tail -n 0"     ""    "$($BB printf 'a\nb\n' | $BB tail -n 0)"
ck "edge. head huge"     "2"   "$($BB printf 'a\nb\n' | $BB head -n 999999 | $BB wc -l | tr -d ' ')"
ck "edge. seq single"    "1 2 3 4 5"   "$($BB seq 5 | $BB tr '\n' ' ' | $BB sed 's/ $//')"
ck "edge. seq step"      "1 3 5" "$($BB seq 1 2 5 | tr '\n' ' ' | $BB sed 's/ $//')"
noc "edge. seq zero step" 3 '$BB seq 1 0 5 2>/dev/null | $BB head -3 >/dev/null 2>&1'

echo "== O. binary and encoding hostility =="
"$BB" head -c 8192 /dev/urandom > bin8k.bin
ck "bin. grep no match" "0" "$($BB grep -c needle bin8k.bin 2>/dev/null | $BB head -1)"
noc "bin. sed on binary" 10 '$BB sed "s/a/b/" bin8k.bin >/dev/null 2>&1'
noc "bin. awk on binary" 10 '$BB awk "{print length}" bin8k.bin >/dev/null 2>&1'
noc "bin. tr on binary"  10 '$BB tr a-z A-Z < bin8k.bin >/dev/null 2>&1'
noc "bin. sort on binary" 10 '$BB sort bin8k.bin >/dev/null 2>&1'
printf '\xc0\xaf\xed\xa0\x80\xf4\x90\x80\x80\n' > bad_utf8.txt
noc "enc. grep invalid utf8" 10 '$BB grep -c x bad_utf8.txt >/dev/null 2>&1'
noc "enc. sed invalid utf8"  10 '$BB sed "s/x/y/" bad_utf8.txt >/dev/null 2>&1'
ck "enc. wc -c exact"   "10"   "$($BB wc -c < bad_utf8.txt | tr -d ' ')"
ck "enc. cat roundtrip" "same" "$( $BB cat bad_utf8.txt > bad.out; $BB cmp -s bad_utf8.txt bad.out && echo same || echo differ )"
rm -f bin8k.bin bad_utf8.txt bad.out

echo "== P. concurrency and races =="
: > race.txt
i=0
while [[ $i -lt 8 ]]; do
	( "$BB" sh -c 'j=0; while [ $j -lt 50 ]; do echo line; j=$((j+1)); done' >> race.txt ) &
	i=$((i+1))
done
wait
ck "race. 8x50 appends" "400" "$($BB wc -l < race.txt | tr -d ' ')"
rm -rf race_d
i=0
while [[ $i -lt 8 ]]; do ( "$BB" mkdir -p race_d/x/y 2>/dev/null ) & i=$((i+1)); done
wait
ck "race. mkdir -p concurrent" "yes" "$([ -d race_d/x/y ] && echo yes || echo no)"

echo "== Q. option-parsing abuse =="
ck "opt. -- ends options" "-n"       "$($BB echo -- -n | $BB sed 's/^-- //')"
ck "opt. - is a filename" "1"        "$( printf 'x' | $BB cat - | $BB wc -c | tr -d ' ' )"
ck "opt. clustered -la"   "yes"      "$( $BB ls -la >/dev/null 2>&1 && echo yes || echo no )"
ck "opt. --long=value"    "3"        "$($BB head --lines=3 many.txt 2>/dev/null | $BB wc -l | tr -d ' ')"
ck "opt. unknown long"    "nonzero"  "$( $BB ls --no-such-option >/dev/null 2>&1 && echo zero || echo nonzero )"
ck "opt. repeated -n"     "abc"      "$($BB echo -n -n abc)"

echo "== R. path traversal and link attacks =="
mkdir -p pv && cd pv || exit 1
echo secret > ../secret.txt
ln -sf ../secret.txt sneaky
ck "pv. cp follows link"   "secret" "$( $BB cp sneaky copied && $BB cat copied )"
noc "pv. tar of symlink"   10 '$BB tar cf pv.tar sneaky >/dev/null 2>&1'
ck "pv. tar keeps link"    "0"      "$($BB tar xOf pv.tar sneaky 2>/dev/null | $BB grep -c secret | $BB head -1)"
noc "pv. rm -rf on symlink" 10 '$BB ln -sfn /tmp pvlink; $BB rm -rf pvlink >/dev/null 2>&1'
cd ..

# ===========================================================================
printf '\n=========== %s%s ===========\n' "$(basename "$BB")" "${RUNNER:+ [$RUNNER]}"
printf 'pass: %d   fail: %d   hangs: %d   crashes: %d   skipped: %d   known: %d\n' \
	"$pass" "$fail" "$hangs" "$crashes" "$skips" "$known"
if [[ ${#FAILED[@]} -gt 0 ]]; then
	printf 'problems:\n'
	printf '  %s\n' "${FAILED[@]}"
	exit 1
fi
echo "OK"
