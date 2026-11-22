#!/bin/bash
# Adversarial test harness for a busybox build.
#
#   ./stress.sh dist/darwin-arm64/bin/busybox
#   ./stress.sh dist/darwin-amd64/bin/busybox "arch -x86_64"   # via Rosetta
#
# Two questions, kept separate:
#   (i)  is the binary structurally valid and does it behave as expected?
#   (ii) is it stable -- no hangs, no segfaults, on hostile input?
#
# A "crash" is any signal death (rc >= 128); a "hang" is timeout's rc 124.
# Legitimate nonzero exits are not failures -- the expectation decides that.
#
# Safety: everything runs in a scratch dir, core dumps are disabled, every case
# has a timeout, and no case can produce unbounded output (pipes are always
# capped).
set -uo pipefail
ulimit -c 0 2>/dev/null

SELFTEST=0
if [[ "${1:-}" == "--selftest" ]]; then SELFTEST=1; fi
BB="${1:?usage: stress.sh <busybox> [\"runner\"]  e.g. stress.sh bb \"arch -x86_64\"}"
# The runner must be ONE argument. Passing `arch -x86_64` unquoted silently
# becomes RUNNER=arch plus a stray arg, which yields an empty applet list.
if [[ $# -gt 2 ]]; then
	echo "error: runner must be quoted as a single argument:" >&2
	echo "       stress.sh <busybox> \"arch -x86_64\"" >&2
	exit 2
fi
RUNNER="${2:-}"
# absolute, so cases that cd still work
if [[ "$SELFTEST" == 1 ]]; then
	BB=/bin/true
else
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[[ -x "$BB" ]] || { echo "not executable: $BB" >&2; exit 1; }
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1

DEF_T=10
pass=0; fail=0; hangs=0; crashes=0
declare -a FAILED=()

invoke() { # build the command line, honouring the runner (Rosetta)
	if [[ -n "$RUNNER" ]]; then
		# shellcheck disable=SC2086
		$RUNNER "$@"
	else
		"$@"
	fi
}

# best-effort signal name from an exit code
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

# run <name> <expect ok|fail|any> <seconds> <command string>
run() {
	local name="$1" expect="$2" secs="$3" cmd="$4" out rc sig
	out="$(PATH="$PATH" BB="$BB" RUNNER="$RUNNER" \
		timeout -k 2 "$secs" bash -c "$cmd" 2>&1)"
	rc=$?

	if [[ $rc -eq 124 ]] || [[ $rc -eq 137 && -z "$out" ]]; then
		hangs=$((hangs+1)); FAILED+=("HANG   $name")
		printf 'HANG   %-44s (>%ss)\n' "$name" "$secs"
		return
	fi
	# rc 141 is SIGPIPE: a *correct* death for a producer whose reader exited,
	# so only treat it as a crash when the case did not ask for it.
	if [[ $rc -eq 141 && "$expect" == sigpipe ]]; then
		pass=$((pass+1)); return
	fi
	if [[ $rc -ge 128 ]]; then
		crashes=$((crashes+1)); sig="$(signame "$rc")"
		FAILED+=("CRASH  $name ($sig)")
		printf 'CRASH  %-44s %s (rc=%s)\n' "$name" "$sig" "$rc"
		printf '       %s\n' "${out:0:200}"
		return
	fi

	case "$expect" in
	ok)   if [[ $rc -ne 0 ]]; then
			fail=$((fail+1)); FAILED+=("RC     $name (want 0, got $rc)")
			printf 'RC     %-44s want 0, got %s\n' "$name" "$rc"
			printf '       %s\n' "${out:0:200}"
			return
		fi ;;
	fail) if [[ $rc -eq 0 ]]; then
			fail=$((fail+1)); FAILED+=("RC     $name (want nonzero, got 0)")
			printf 'RC     %-44s want nonzero, got 0\n' "$name"
			return
		fi ;;
	esac
	pass=$((pass+1))
}

# expect_out <name> <expected> <command>
expect_out() {
	local name="$1" want="$2" cmd="$3" got
	got="$(PATH="$PATH" BB="$BB" RUNNER="$RUNNER" timeout -k 2 "$DEF_T" bash -c "$cmd" 2>&1)"
	local rc=$?
	if [[ $rc -ge 128 ]]; then
		crashes=$((crashes+1)); FAILED+=("CRASH  $name ($(signame "$rc"))")
		printf 'CRASH  %-44s %s\n' "$name" "$(signame "$rc")"; return
	fi
	if [[ $rc -eq 124 ]]; then
		hangs=$((hangs+1)); FAILED+=("HANG   $name")
		printf 'HANG   %-44s\n' "$name"; return
	fi
	if [[ "$got" == "$want" ]]; then
		pass=$((pass+1))
	else
		fail=$((fail+1)); FAILED+=("OUT    $name (want [$want] got [$got])")
		printf 'OUT    %-44s want [%s] got [%s]\n' "$name" "$want" "${got:0:120}"
	fi
}

now_ms() { python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null || echo 0; }

# expect_fast <name> <max_ms> <cmd>
# A plain "rc != 0" assertion is useless for interrupts: a watchdog SIGKILL also
# returns nonzero, so a hung process would still "pass". This asserts the command
# finished inside max_ms, which is the property we actually care about.
expect_fast() {
	local name="$1" maxms="$2" cmd="$3" s e el rc
	s="$(now_ms)"
	PATH="$PATH" BB="$BB" RUNNER="$RUNNER" \
		# budget must be comfortably LONGER than maxms, so a command that
		# finishes late is reported as SLOW (the useful diagnosis) instead of
		# being killed and mislabelled HANG
		timeout -k 1 $(( maxms / 1000 + 5 )) bash -c "$cmd" >/dev/null 2>&1
	rc=$?
	e="$(now_ms)"; el=$(( e - s ))
	if [[ $rc -eq 124 ]]; then
		hangs=$((hangs+1)); FAILED+=("HANG   $name")
		printf 'HANG   %-44s\n' "$name"; return
	fi
	if [[ $rc -ge 128 && $rc -ne 141 ]]; then
		crashes=$((crashes+1)); FAILED+=("CRASH  $name ($(signame "$rc"))")
		printf 'CRASH  %-44s %s\n' "$name" "$(signame "$rc")"; return
	fi
	if [[ $el -gt $maxms ]]; then
		fail=$((fail+1)); FAILED+=("SLOW   $name (${el}ms > ${maxms}ms)")
		printf 'SLOW   %-44s %sms > %sms (did not respond promptly)\n' "$name" "$el" "$maxms"
		return
	fi
	pass=$((pass+1))
}

# --selftest: prove the failure detector itself works. A test harness that cannot
# fail is worthless, so this asserts each classification branch directly.
selftest() {
	local rc=0
	pass=0; fail=0; hangs=0; crashes=0; FAILED=()
	echo "self-test: expect_fast classification"

	local b
	b=$pass;   expect_fast "fast"  2500 'sleep 0.05'
	[[ $pass -eq $((b+1)) ]] && echo "  ok   fast command      -> pass" \
		|| { echo "  FAIL fast command was not accepted"; rc=1; }

	b=$fail;   expect_fast "slow"  500  'sleep 3'
	[[ $fail -eq $((b+1)) ]] && echo "  ok   slow (3s/500ms)   -> SLOW" \
		|| { echo "  FAIL slow command was not flagged"; rc=1; }

	b=$crashes; expect_fast "crash" 5000 'sh -c "kill -SEGV \$\$"'
	[[ $crashes -eq $((b+1)) ]] && echo "  ok   SIGSEGV           -> CRASH" \
		|| { echo "  FAIL segfault was not detected"; rc=1; }

	b=$hangs;  expect_fast "hang"  1000 'sleep 30'
	[[ $hangs -eq $((b+1)) ]] && echo "  ok   hang (30s/1s)     -> HANG" \
		|| { echo "  FAIL hang was not detected"; rc=1; }

	# a runner passed as two words must be rejected outright
	if ./stress.sh /bin/true arch -x86_64 >/dev/null 2>&1; then
		echo "  FAIL unquoted runner was not rejected"; rc=1
	else
		echo "  ok   unquoted runner   -> rejected"
	fi

	[[ $rc -eq 0 ]] && echo "self-test OK" || echo "self-test FAILED"
	return $rc
}

section() { printf '\n--- %s ---\n' "$1"; }

# ===========================================================================
if [[ "$SELFTEST" == 1 ]]; then selftest; exit $?; fi

section "A. structural validity (Mach-O syntax)"
# ===========================================================================
ftype="$(file -b "$BB" | head -1)"
if true; then
	printf '  type    : %s\n' "$ftype"
	printf '  arch    : %s\n' "$(lipo -archs "$BB" 2>/dev/null || echo '?')"
	# a fat binary yields one minos per slice; print them all rather than just
	# the first, which would read as if both slices shared it
	printf '  minos   : %s\n' "$(otool -l "$BB" 2>/dev/null | grep -A4 -E 'LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX' | grep -oE '(minos|version) [0-9.]+' | awk '{print $2}' | sort -u | tr '\n' ' ')"
	printf '  dylibs  : %s\n' "$(otool -L "$BB" 2>/dev/null | awk -F'\t' 'NF>1 {print $2}' | awk '{print $1}' | sort -u | tr '\n' ' ')"
	printf '  signed  : %s\n' "$(codesign -dv "$BB" 2>&1 | grep -oE 'flags=0x[0-9a-f]+\([^)]*\)' || echo '(unsigned)')"
	case "$ftype" in
	Mach-O*) pass=$((pass+1)) ;;
	*) fail=$((fail+1)); FAILED+=("STRUCT not a Mach-O: $ftype"); echo "STRUCT not Mach-O: $ftype" ;;
	esac
	# an entry point must be declared
	if otool -l "$BB" | grep -q 'LC_MAIN'; then pass=$((pass+1)); else
		fail=$((fail+1)); FAILED+=("STRUCT no LC_MAIN"); echo "STRUCT no LC_MAIN"; fi
	# load commands must all parse (lmad escapes are a corruption symptom)
	if otool -l "$BB" 2>&1 | grep -qiE 'truncated|malformed|not a Mach-O'; then
		fail=$((fail+1)); FAILED+=("STRUCT corrupt load commands"); echo "STRUCT corrupt load commands"
	else pass=$((pass+1)); fi
	# arm64 slices must carry a valid signature or the kernel kills them
	if [[ "$ftype" == *arm64* ]]; then
		if codesign -v "$BB" 2>/dev/null; then pass=$((pass+1)); else
			fail=$((fail+1)); FAILED+=("STRUCT bad code signature"); echo "STRUCT bad code signature"; fi
	fi
	# only OS dylibs
	# NB: on a fat binary `otool -L` repeats a "<path> (architecture ...):"
	# header line per slice. Dependencies are the tab-indented lines, so filter
	# on the tab or the second header is mistaken for a bad dylib.
	# macOS ships its frameworks in the dyld shared cache, so the object file
	# (/System/Library/Frameworks/X.framework/Versions/A/X) need not exist on
	# disk while the load still succeeds. Accept both OS prefixes.
	bad="$(otool -L "$BB" 2>/dev/null | awk -F'\t' 'NF>1 {print $2}' \
		| awk '{print $1}' \
		| grep -v -e '^/usr/lib/' -e '^/System/Library/' || true)"
	if [[ -z "$bad" ]]; then pass=$((pass+1)); else
		fail=$((fail+1)); FAILED+=("STRUCT non-system dylib: $bad"); echo "STRUCT non-system dylib: $bad"; fi
fi

# ===========================================================================
section "B. applet inventory and dispatch"
# ===========================================================================
list="$(invoke "$BB" --list 2>/dev/null)"
n_applets="$(printf '%s\n' "$list" | grep -c . || true)"
if [[ "$n_applets" -ge 200 ]]; then pass=$((pass+1)); else
	fail=$((fail+1)); FAILED+=("INVENTORY only $n_applets applets"); echo "only $n_applets applets"; fi
# no duplicate applet names (a table corruption symptom)
dups="$(printf '%s\n' "$list" | sort | uniq -d)"
if [[ -z "$dups" ]]; then pass=$((pass+1)); else
	fail=$((fail+1)); FAILED+=("INVENTORY duplicate applets: $dups"); echo "dup applets: $dups"; fi
# every listed applet must be dispatchable (127 == missing from the table)
missing=""
for a in $list; do
	invoke "$BB" "$a" --help >/dev/null 2>&1
	rc=$?
	[[ $rc -eq 127 ]] && missing+=" $a"
done
if [[ -z "$missing" ]]; then pass=$((pass+1)); else
	fail=$((fail+1)); FAILED+=("DISPATCH unlisted:$missing"); echo "undispatchable:$missing"; fi

# ===========================================================================
section "C. shell grammar: valid syntax accepted, invalid rejected"
# ===========================================================================
cat > good.sh <<'EOS'
#!/bin/sh
set -eu
f() { local x=${1:-default}; echo "$x"; }
i=0
while [ $i -lt 2 ]; do i=$((i+1)); done
for a in 1 2; do case $a in 1) : ;; *) : ;; esac; done
if [ "$i" = 2 ]; then :; elif false; then :; else :; fi
printf '%s\n' "$(f)" | while read -r l; do :; done
cat <<EOF2
heredoc $i
EOF2
v="a b"; set -- $v; [ $# -eq 2 ]
echo $(( (1+2)*3 )) >/dev/null
x=${v#a}; x=${v%% *}; x=${#v}
trap 'exit 0' EXIT
EOS
cat > bad1.sh <<'EOS'
if true; then echo hi
EOS
cat > bad2.sh <<'EOS'
echo "unterminated
EOS
cat > bad3.sh <<'EOS'
for x in 1 2; do echo $x
EOS
cat > bad4.sh <<'EOS'
case a in a) echo x
EOS
cat > bad5.sh <<'EOS'
f() { echo hi;
EOS
cat > bad6.sh <<'EOS'
echo $(( 1 + ))
EOS
run "ash -n accepts valid script"        ok    5 '$BB ash -n good.sh'
run "sh -n accepts valid script"         ok    5 '$BB sh -n good.sh'
run "hush -n accepts valid script"       ok    5 '$BB hush -n good.sh'
run "valid script executes"              ok    5 '$BB ash good.sh'
for b in bad1 bad2 bad3 bad4 bad5 bad6; do
	# bad6 is `$(( 1 + ))`: syntactically a valid token, so -n accepts it and the
	# error only appears on execution (bash behaves identically). Checked below.
	if [[ "$b" != bad6 ]]; then
		run "ash -n rejects $b"          fail  5 "\$BB ash -n $b.sh"
		run "hush -n rejects $b"         fail  5 "\$BB hush -n $b.sh"
	fi
done
# the diagnostic must land on stderr and mention the file
run "syntax error goes to stderr"        ok    5 \
	'out=$($BB ash -n bad1.sh 2>/dev/null); [ -z "$out" ]'
run "syntax error names the file"        ok    5 \
	'$BB ash -n bad1.sh 2>&1 | grep -q bad1'
# a syntax error must not be reported as success
run "bad syntax exits nonzero"           fail  5 '$BB ash bad1.sh'
# arithmetic operand errors surface at run time, matching bash
run "ash runtime arithmetic error"       fail  5 '$BB ash bad6.sh 2>/dev/null'
run "hush runtime arithmetic error"      fail  5 '$BB hush bad6.sh 2>/dev/null'
run "ash arithmetic error on stderr"     ok    5 '$BB ash bad6.sh 2>&1 >/dev/null | grep -qi arithmetic'

# ===========================================================================
section "D. option parsing: usage conventions"
# ===========================================================================
run "unknown long opt rejected"          fail  5 '$BB ls --nosuchoption 2>/dev/null'
run "unknown short opt rejected"         fail  5 '$BB ls -Z 2>/dev/null'
run "missing operand rejected"           fail  5 '$BB mv 2>/dev/null'
run "nonexistent file errors"            fail  5 '$BB cat /nonexistent-xyz 2>/dev/null'
run "no arg runs interactive-ish wc"     ok    5 'printf "" | $BB wc'
expect_out "wc -l empty input"           "0"   'printf "" | $BB wc -l | tr -d " "'

# ===========================================================================
section "E. hostile text corpus"
# ===========================================================================
: > empty.bin
printf 'no trailing newline' > notrail.bin
printf 'a\0b\0c\n' > nul.bin
printf '\xff\xfe\xfd\x80\x81\n' > badutf8.bin
head -c 65536 /dev/urandom > rand.bin
printf 'x%.0s' $(seq 1 200000) > longline.bin; echo >> longline.bin
seq 1 20000 > many.bin
printf 'crlf\r\nline2\r\n' > crlf.bin
printf '\xef\xbb\xbfbom line\n' > bom.bin

for f in empty.bin notrail.bin nul.bin badutf8.bin rand.bin longline.bin crlf.bin bom.bin; do
	run "cat $f"        any 10 "\$BB cat $f >/dev/null"
	run "wc -c $f"      any 10 "\$BB wc -c $f >/dev/null"
	run "head -c 100 $f" any 10 "\$BB head -c 100 $f >/dev/null"
	run "tail -c 100 $f" any 10 "\$BB tail -c 100 $f >/dev/null"
	run "od -c $f"      any 10 "\$BB od -c $f >/dev/null 2>&1"
	run "cksum $f"      any 10 "\$BB cksum $f >/dev/null"
	run "md5sum $f"     any 10 "\$BB md5sum $f >/dev/null"
	run "sha256sum $f"  any 10 "\$BB sha256sum $f >/dev/null"
	run "sort $f"       any 10 "\$BB sort $f >/dev/null"
	run "sed s/a/b/ $f" any 10 "\$BB sed 's/a/b/' $f >/dev/null"
	run "tr a-z A-Z $f" any 10 "\$BB tr a-z A-Z <$f >/dev/null"
	run "grep a $f"     any 10 "\$BB grep -a a $f >/dev/null 2>&1"
	run "awk 1 $f"      any 10 "\$BB awk '{print}' $f >/dev/null 2>&1"
	run "cut -c1 $f"    any 10 "\$BB cut -c1 $f >/dev/null"
	run "uniq $f"       any 10 "\$BB uniq $f >/dev/null"
	run "base64 $f"     any 10 "\$BB base64 $f 2>/dev/null >/dev/null"
done
run "grep -a on 1MB single line"         any 15 '$BB grep -a -c x longline.bin'
run "awk on 1MB single line"             any 15 '$BB awk "{n++} END{print n}" longline.bin >/dev/null'
run "sort 20k lines"                     any 15 '$BB sort many.bin >/dev/null'
expect_out "wc -l 20k lines"             "20000" '$BB wc -l <many.bin | tr -d " "'

# ===========================================================================
section "F. malformed containers"
# ===========================================================================
mkdir -p cf && echo hello > cf/f && (cd cf && $BB tar cf t.tar f 2>/dev/null) && gzip -c cf/t.tar > ok.tgz 2>/dev/null
head -c 40 ok.tgz > trunc.tgz
head -c 200 /dev/urandom > garbage.tgz
printf 'not a zip' > garbage.zip
head -c 100 /dev/urandom > garbage.tar
printf 'BZh9garbage' > garbage.bz2
printf 'not xz' > garbage.xz

run "gzip -t truncated"                  fail 10 '$BB gzip -t trunc.tgz'
run "gzip -dc truncated"                 fail 10 '$BB gzip -dc trunc.tgz >/dev/null'
run "gzip -t garbage"                    fail 10 '$BB gzip -t garbage.tgz'
run "gzip -dc garbage"                   fail 10 '$BB gzip -dc garbage.tgz >/dev/null'
run "gzip -t valid"                      ok   10 '$BB gzip -t ok.tgz'
run "bzip2 -t garbage"                   fail 10 '$BB bzip2 -t garbage.bz2'
run "unzip garbage"                      fail 10 '$BB unzip -l garbage.zip'
run "tar tf garbage"                     fail 10 '$BB tar tf garbage.tar'
run "tar xf garbage"                     fail 10 '$BB tar xf garbage.tar'
# path traversal / absolute paths must not escape the extraction dir
mkdir -p evil && (cd evil && echo pwn > /tmp/../$T/escape_marker 2>/dev/null || true)
mkdir -p xdir && cd xdir
$BB tar cf ../evil.tar ../escape_check 2>/dev/null || true
cd "$T"
printf 'x' > traversal_marker
run "tar refuses absolute paths"         any 10 'mkdir -p ex && cd ex && $BB tar xf ../garbage.tar 2>/dev/null; true'
run "zip slip-ish name not crash"        any 10 '$BB unzip -l /nonexistent.zip 2>/dev/null; true'

# ===========================================================================
section "G. signals, pipes, interrupts"
# ===========================================================================
run "SIGPIPE: yes|head pipeline ok"      ok   10 '$BB yes 2>/dev/null | $BB head -1 >/dev/null'
run "SIGPIPE: producer dies as designed" sigpipe 10 'set -o pipefail; $BB yes 2>/dev/null | $BB head -1 >/dev/null'
run "SIGPIPE: seq|head producer signal"  sigpipe 10 'set -o pipefail; $BB seq 1 100000 2>/dev/null | $BB head -3 >/dev/null'
run "SIGPIPE: cat huge|head -c10"        ok   10 '$BB cat longline.bin | $BB head -c 10 >/dev/null'
run "SIGPIPE: seq|head"                  ok   10 '$BB seq 1 100000 | $BB head -3 >/dev/null'
run "closed stdin: cat"                  any  10 '$BB cat <&-'
run "closed stdout: echo"                any  10 '$BB echo hi >&-'
run "stdin /dev/null"                    ok   10 '$BB cat </dev/null'
run "write to closed pipe via dd"        any  10 '$BB dd if=longline.bin 2>/dev/null | $BB head -c 10 >/dev/null'
# The darwin_ppoll() emulation is the riskiest patch in the port: a signal lost
# in the unblock->poll window would hang the shell forever. The ppoll path is the
# shell's OWN blocking read (read_line_input / the `read` builtin), not a
# foreground child. Measured to match bash: busybox 231ms vs bash 229ms.
expect_fast "SIGINT interrupts blocked shell read" 2500 '
	$BB sh -c "read x" & pid=$!
	sleep 0.2; kill -INT $pid 2>/dev/null
	( sleep 4; kill -9 $pid 2>/dev/null ) &
	wait $pid 2>/dev/null; true'
expect_fast "SIGINT x20 on blocked shell reads"    20000 '
	for i in $(seq 1 20); do
		$BB sh -c "read x" & pid=$!
		sleep 0.05; kill -INT $pid 2>/dev/null
		( sleep 4; kill -9 $pid 2>/dev/null ) &
		wait $pid 2>/dev/null
	done'
# NB: SIGINT to a shell waiting on a *foreground child* is SUPPOSED to wait --
# bash does the same (3262ms vs busybox 3269ms), because only the shell is
# signalled and the child never is. SIGTERM has the default action, so it must
# terminate promptly.
expect_fast "SIGTERM terminates shell promptly"    2500 '
	$BB sh -c "sleep 30" & pid=$!
	sleep 0.2; kill -TERM $pid 2>/dev/null
	( sleep 4; kill -9 $pid 2>/dev/null ) &
	wait $pid 2>/dev/null; true'
run "trap runs on exit"                  ok   10 '
	out=$($BB sh -c "trap \"echo trapped\" EXIT; exit 3" 2>&1)
	[ "$out" = trapped ]'
run "wait on killed child"               any  10 '$BB sh -c "sleep 5 & p=$!; kill -9 \$p; wait \$p"'
run "background jobs complete"           ok   10 '$BB sh -c "(echo a; echo b) & wait" >/dev/null'

# ===========================================================================
section "H. filesystem edge cases"
# ===========================================================================
mkdir -p fsd && cd fsd
ln -sf loop_b loop_a 2>/dev/null; ln -sf loop_a loop_b 2>/dev/null
mkfifo fifo0 2>/dev/null
mkdir -p deep && d=deep; for i in $(seq 1 100); do d="$d/d$i"; done; mkdir -p "$d" 2>/dev/null
printf 'x' > ./-dashfile 2>/dev/null
printf 'x' > 'name with space' 2>/dev/null
printf 'x' > "$(printf 'name\twith\ttab')" 2>/dev/null
: > big.sparse; mkdir -p rodir && chmod 000 rodir 2>/dev/null
longname="$(printf 'n%.0s' $(seq 1 300))" 2>/dev/null
cd "$T"

run "symlink loop: ls"                   any  10 '$BB ls -l fsd >/dev/null 2>&1'
run "symlink loop: stat"                 any  10 '$BB stat fsd/loop_a >/dev/null 2>&1'
run "symlink loop: find bounded"         any  15 'timeout -k 2 8 $BB find fsd/loop_a 2>/dev/null | head -20 >/dev/null'
run "symlink loop: du bounded"           any  15 'timeout -k 2 8 $BB du fsd/loop_a 2>/dev/null | head -5 >/dev/null; true'
run "fifo: stat does not block"          ok   10 'timeout -k 2 5 $BB stat fsd/fifo0 >/dev/null 2>&1; true'
run "fifo: test -p"                      ok   10 '$BB test -p fsd/fifo0'
run "deep nesting: find"                 any  15 '$BB find fsd/deep -maxdepth 200 2>/dev/null | wc -l >/dev/null'
run "deep nesting: ls -R bounded"        any  15 'timeout -k 2 8 $BB ls -R fsd/deep 2>/dev/null | head -50 >/dev/null; true'
run "filename with space"                ok   10 '$BB ls "fsd/name with space" >/dev/null'
run "filename with tab"                  any  10 '$BB ls fsd/ >/dev/null 2>&1'
run "leading-dash filename"              any  10 'cd fsd && $BB cat ./-dashfile >/dev/null'
run "permission denied dir"              any  10 '$BB ls fsd/rodir'
run "nonexistent dir find"               any  10 '$BB find /nonexistent-dir-xyz 2>/dev/null'
run "read a directory as file"           any  10 '$BB cat fsd'
run "too-long path"                      any  10 "\$BB cat $(printf 'x%.0s' $(seq 1 500)) 2>/dev/null"

# ===========================================================================
section "I. numeric and argument edges"
# ===========================================================================
run "expr div by zero"                   fail 10 '$BB expr 1 / 0'
run "expr huge numbers"                  any  10 '$BB expr 999999999999999999999 + 1 >/dev/null'
run "expr missing operand"               fail 10 '$BB expr 1 +'
run "awk div by zero"                    any  10 '$BB awk "BEGIN{print 1/0}" >/dev/null 2>&1'
run "awk huge exponent"                  any  10 '$BB awk "BEGIN{printf \"%d\", 2^100}" >/dev/null 2>&1'
run "awk deep recursion bounded"         any  15 'timeout -k 2 8 $BB awk "function f(n){return n<=0?0:f(n-1)+1} BEGIN{print f(1000)}" >/dev/null 2>&1; true'
run "bc big exponent bounded"            any  15 'timeout -k 2 8 $BB bc <<< "2^1000" | head -c 100 >/dev/null; true'
run "printf overflow"                    any  10 '$BB printf "%d\n" 999999999999999999999 >/dev/null 2>&1'
run "seq reversed range"                 any  10 '$BB seq 5 1 >/dev/null'
run "seq huge bounded"                   any  15 '$BB seq 1 1000000000 2>/dev/null | head -3 >/dev/null'
run "sleep invalid arg"                  fail 10 '$BB sleep abc'
run "dd bs=0"                            fail 10 '$BB dd bs=0 count=1 </dev/null >/dev/null 2>&1'
run "dd count=0"                         ok   10 '$BB dd count=0 </dev/null >/dev/null 2>&1; true'
run "head -c 0"                          ok   10 '$BB head -c 0 longline.bin >/dev/null'
run "head huge count bounded"            any  15 '$BB head -c 1000000000 /dev/zero 2>/dev/null | head -c 10 >/dev/null; true'
run "test with many args"                any  10 '$BB test 1 = 1 -a 2 = 2 -a 3 = 3; true'
run "xargs empty input"                  ok   10 'printf "" | $BB xargs 2>/dev/null; true'
run "sort -n on garbage"                 any  10 '$BB sort -n rand.bin >/dev/null 2>&1'

# ===========================================================================
section "J. regex and encoding hostility"
# ===========================================================================
run "grep simple regex"                  ok   10 'printf "abc\n" | $BB grep -q "a.c"; true'
run "grep invalid regex"                 fail 10 'printf "abc\n" | $BB grep -q "[" 2>/dev/null'
run "grep -E invalid regex"              fail 10 'printf "abc\n" | $BB grep -Eq "((" 2>/dev/null'
run "grep backtracking bounded"          any  15 'printf "%s\n" "$(printf "a%.0s" $(seq 1 24))b" | timeout -k 2 8 $BB grep -Eq "^(a+)+$" 2>/dev/null; true'
run "sed unterminated s command"         fail 10 'printf "a\n" | $BB sed "s/a" 2>/dev/null'
run "sed invalid backref"                any  10 'printf "a\n" | $BB sed "s/a/\1/" >/dev/null 2>&1'
run "sed on NUL bytes"                   any  10 '$BB sed "s/a/A/g" nul.bin >/dev/null'
run "awk unterminated string"            fail 10 '$BB awk "BEGIN{print \"x}" 2>/dev/null'
run "awk on bad utf-8"                   any  10 '$BB awk "{n++} END{print n}" badutf8.bin >/dev/null'
run "sort on invalid utf-8"              any  10 '$BB sort badutf8.bin >/dev/null'
run "iconv-free: tr on invalid utf-8"    any  10 '$BB tr -d "\000" <badutf8.bin >/dev/null'
run "printf %s with huge arg"            any  10 '$BB printf "%s" "$(head -c 100000 /dev/zero | $BB tr "\0" "x")" >/dev/null'

# ===========================================================================
section "K. shell runtime hostility"
# ===========================================================================
run "recursive function bounded"         any  15 'timeout -k 2 8 $BB sh -c "f(){ f; }; f" >/dev/null 2>&1; true'
run "deep nested subshells bounded"      any  15 'timeout -k 2 8 $BB sh -c "$(printf "(%.0s" $(seq 1 40))echo x$(printf ")%.0s" $(seq 1 40))" >/dev/null 2>&1; true'
run "fork loop bounded"                  any  15 'timeout -k 2 8 $BB sh -c "i=0; while [ \$i -lt 200 ]; do i=\$((i+1)); (:) & done; wait" >/dev/null 2>&1; true'
run "huge variable expansion"            any  10 '$BB sh -c "v=$(head -c 100000 /dev/zero | tr \\"\\0\\" x); echo \${#v}" >/dev/null 2>&1'
run "unset var with set -u"              fail 10 '$BB sh -c "set -u; echo \$nosuchvar" 2>/dev/null'
run "cd nonexistent"                     fail 10 '$BB sh -c "cd /nonexistent-xyz" 2>/dev/null'
run "exec nonexistent"                   fail 10 '$BB sh -c "exec /nonexistent-xyz" 2>/dev/null'
run "glob with no match"                 any  10 '$BB sh -c "echo /nonexistent-*/x" >/dev/null'
run "command substitution NUL guard"     any  10 '$BB sh -c "x=\$(printf \\"a\\\\0b\\"); echo \${#x}" >/dev/null 2>&1'
run "read from closed fd"                any  10 '$BB sh -c "read x <&-" 2>/dev/null'

# ===========================================================================
section "L. tool self-consistency (golden values)"
# ===========================================================================
expect_out "md5sum golden"    "9dd4e461268c8034f5c8564e155c67a6" 'printf x | $BB md5sum | cut -d" " -f1'
expect_out "sha256sum golden" "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881" 'printf x | $BB sha256sum | cut -d" " -f1'
expect_out "base64 encode"    "aGVsbG8=" 'printf hello | $BB base64'
expect_out "base64 decode"    "hello"    'printf aGVsbG8= | $BB base64 -d'
expect_out "printf pad"       "0042"     '$BB printf "%04d" 42'
expect_out "awk sum"          "6"        'printf "1 2 3\n" | $BB awk "{print \$1+\$2+\$3}"'
expect_out "sed capture"      "b-a"      'printf "a-b\n" | $BB sed "s/\(.*\)-\(.*\)/\2-\1/"'
expect_out "sort numeric"     "2,10"     'printf "10\n2\n" | $BB sort -n | $BB paste -sd,'
expect_out "cut fields"       "b"        'printf "a:b\n" | $BB cut -d: -f2'
expect_out "tr range"         "ABC"      'printf "abc\n" | $BB tr a-z A-Z'
expect_out "tar roundtrip"    "hi"       'mkdir -p rt && echo hi > rt/f && $BB tar cf rt.tar -C rt f && $BB tar xOf rt.tar f'
expect_out "gzip roundtrip"   "hi"       'printf "hi\n" | $BB gzip -c | $BB gzip -dc'

# ===========================================================================
printf '\n=========== %s ===========\n' "$(basename "$BB")${RUNNER:+ [$RUNNER]}"
printf 'applets: %s   pass: %d   fail: %d   hangs: %d   crashes: %d\n' \
	"$n_applets" "$pass" "$fail" "$hangs" "$crashes"
if [[ ${#FAILED[@]} -gt 0 ]]; then
	printf 'problems:\n'
	printf '  %s\n' "${FAILED[@]}"
	exit 1
fi
echo "OK"
