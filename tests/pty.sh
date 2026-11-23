#!/bin/bash
# 100 checks on the pty a guest runs under: `run --pty` / `-Y`, and the
# modifiers --pty-raw, --pty-split, --pty-size, plus the stdin feed, EOF
# handling, capture fidelity, exit codes, deadline, environment inheritance and
# the JSON/meta surface. `sh --pty` is covered at the end.
#
#   ./tests/pty.sh dist/darwin-arm64/bin/busybox
#   docker run --rm --platform linux/arm64 -v "$PWD:/w:ro" almalinux:9 \
#       bash /w/tests/pty.sh /w/dist/linux-arm64/bin/busybox
#
# Every guest runs under `timeout`, so a hang fails a check instead of the
# suite: the whole point of the pty work is that the wrapper cannot wedge.
set -u
BB="${1:?usage: pty.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[ -x "$BB" ] || { echo "not executable: $BB" >&2; exit 1; }
export BB
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
# The guest inherits our environment by design, so -D and TMPDIR are set for the
# wrapper only and never leak into a check that compares environments.
SCRATCH="$T/scratch"
mkdir -p "$SCRATCH"
export TMPDIR="$SCRATCH/tmp"
mkdir -p "$TMPDIR"

pass=0 fail=0 total=0
ck() { # ck <name> <expected> <actual>
	total=$((total + 1))
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL %-56s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}
sec() { printf '== %s ==\n' "$1"; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
len() { "$BB" wc -c < "$1" | "$BB" tr -d ' '; }
sha() { "$BB" sha256sum < "$1" | "$BB" cut -d' ' -f1; }
# run the wrapper with a hard cap so a wedge is a failed check, not a stuck suite
rt() { "$BB" timeout 30 "$BB" run "$@" < /dev/null; }

if ! "$BB" --list | "$BB" grep -qx run; then
	echo "skip: run applet not in this build"
	exit 0
fi

# ---------------------------------------------------------------- fixtures
"$BB" seq 1 40000 > lines.in
"$BB" head -n 40 lines.in > forty.in
"$BB" head -c 4096 lines.in > mid.in
"$BB" head -c 50 lines.in | "$BB" head -c 49 > partial.in     # no trailing \n
printf 'a\r\nb\r\n' > crlf.in
"$BB" dd if=/dev/zero bs=1024 count=256 2>/dev/null | "$BB" tr '\0' 'x' > big.in
# 4096 distinct-ish bytes, including NUL and the high half
"$BB" awk 'BEGIN{for(i=0;i<256;i++)printf "%c",i}' > bin.out
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do cat bin.out; done > bin.dat
# one line of 1023 bytes (fits every platform's canonical limit) and one of 5000
"$BB" head -c 1023 lines.in | "$BB" tr '\n' 'y' > line1023.in; printf '\n' >> line1023.in
"$BB" head -c 5000 lines.in | "$BB" tr '\n' 'y' > line5000.in; printf '\n' >> line5000.in
"$BB" head -c 3000 lines.in | "$BB" tr '\n' 'y' > line3000.in; printf '\n' >> line3000.in

# ================================================================ S1 usage
sec "S1 usage and option plumbing"
ck "S1.1 run --help mentions --pty" yes \
	"$(has "$("$BB" run --help 2>&1)" '--pty')"
ck "S1.2 run --help mentions --pty-size" yes \
	"$(has "$("$BB" run --help 2>&1)" '--pty-size')"
rt -D "$T/d.1.3" -Y --quiet -- "$BB" sh -c '[ -t 1 ] && echo tty' > "$T/o"
ck "S1.3 -Y is --pty" "tty" "$(cat "$T/o")"
rt --pty-size 0x0 -- true > /dev/null 2>"$T/e"; ck "S1.4 --pty-size 0x0 is an error" 2 $?
ck "S1.5 --pty-size 0x0 says why" yes \
	"$(has "$(cat "$T/e")" 'COLSxROWS')"
rt --pty-size abc -- true > /dev/null 2>&1; ck "S1.6 --pty-size abc is an error" 2 $?
rt --pty-size 10 -- true > /dev/null 2>&1; ck "S1.7 --pty-size 10 is an error" 2 $?
rt --pty-nope -- true > /dev/null 2>&1; ck "S1.8 unknown --pty-nope is an error" 2 $?

# ==================================================== S2 terminal identity
sec "S2 the guest really has a terminal"
rt -D "$T/d.2" --pty --quiet -- "$BB" sh -c 'tty' > "$T/o"
ck "S2.1 tty is a device path" yes "$(has "$(cat "$T/o")" '/dev/')"
rt --pty --quiet -- "$BB" sh -c '[ -t 0 ] && echo y' > "$T/o"
ck "S2.2 isatty(0)" "y" "$(cat "$T/o")"
rt --pty --quiet -- "$BB" sh -c '[ -t 1 ] && echo y' > "$T/o"
ck "S2.3 isatty(1)" "y" "$(cat "$T/o")"
rt --pty --quiet -- "$BB" sh -c '[ -t 2 ] && echo y' > "$T/o"
ck "S2.4 isatty(2), merged mode" "y" "$(cat "$T/o")"
rt --pty --quiet -- "$BB" sh -c 'exec 3</dev/tty && echo opened' > "$T/o"
ck "S2.5 /dev/tty can be opened" "opened" "$(cat "$T/o")"
rt --pty --quiet -- "$BB" sh -c 'echo via-dev-tty >/dev/tty' > "$T/o"
ck "S2.6 writing /dev/tty lands in the capture" "via-dev-tty" "$(cat "$T/o")"
rt --pty --quiet -- "$BB" sh -c 'stty size' > "$T/o"
ck "S2.7 default size is 80x24" "24 80" "$(cat "$T/o")"
rt --pty --pty-size 100x30 --quiet -- "$BB" sh -c 'stty size' > "$T/o"
ck "S2.8 --pty-size 100x30" "30 100" "$(cat "$T/o")"
rt --pty --pty-size 1x1 --quiet -- "$BB" sh -c 'stty size' > "$T/o"
ck "S2.9 --pty-size 1x1" "1 1" "$(cat "$T/o")"
rt --pty --quiet -- "$BB" sh -c 'stty -a' > "$T/o"
ck "S2.10 the terminal does not echo" yes "$(has "$(cat "$T/o")" ' -echo')"
ck "S2.11 output is not CRLF-translated" yes "$(has "$(cat "$T/o")" ' -onlcr')"
rt --pty --quiet -- "$BB" sh -c \
	'echo "$$ $("$BB" ps -o pid,pgid | "$BB" awk -v p=$$ "\$1==p{print \$2}")"' > "$T/o"
read -r guestpid guestpgid < "$T/o"
ck "S2.12 guest pgid == guest pid (a group kill reaches it)" "$guestpid" "$guestpgid"

# ============================================================ S3 split mode
sec "S3 --pty-split keeps stderr on its own pipe"
rt --pty-split --quiet -- "$BB" sh -c '[ -t 0 ] && echo y' > "$T/o"
ck "S3.1 split: isatty(0)" "y" "$(cat "$T/o")"
rt --pty-split --quiet -- "$BB" sh -c '[ -t 1 ] && echo y' > "$T/o"
ck "S3.2 split: isatty(1)" "y" "$(cat "$T/o")"
rt --pty-split --quiet -- "$BB" sh -c '[ -t 2 ] && echo y || echo n' > "$T/o"
ck "S3.3 split: isatty(2) is false" "n" "$(cat "$T/o")"
rt --pty-split -D "$T/d.3.4" -- sh -c 'echo out; echo err >&2' > /dev/null 2>&1
ck "S3.4 split: stdout artifact" "out" "$(cat "$T/d.3.4/R1/stdout")"
ck "S3.5 split: stderr artifact" "err" "$(cat "$T/d.3.4/R1/stderr")"
rt --pty -D "$T/d.3.6" -- sh -c 'echo out; echo err >&2' > /dev/null 2>&1
ck "S3.6 merged: both streams in stdout, stderr empty" \
	"$(cat "$T/d.3.6/R1/stdout")|$(len "$T/d.3.6/R1/stderr")" "out
err|0"

# ============================================================= S4 raw mode
sec "S4 --pty-raw"
rt --pty-raw --quiet -- "$BB" sh -c 'stty -a' > "$T/o"
ck "S4.1 raw: -icanon" yes "$(has "$(cat "$T/o")" ' -icanon')"
# No line discipline means no VEOF, so a reader cannot be given an EOF: with a
# deadline it must come back as exit 3, not as a hang.
rt --pty-raw --timeout 1 --quiet --stdin forty.in -- "$BB" cat > /dev/null 2>&1
ck "S4.2 raw: a reader waiting for EOF hits the deadline" 3 $?
rt --pty --timeout 10 --quiet --stdin forty.in -- "$BB" cat > /dev/null 2>&1
ck "S4.3 cooked: VEOF gives the reader an EOF" 0 $?
rt --pty-raw -D "$T/d.4.4" --stdin line3000.in --quiet -- "$BB" head -c 3001 \
	> /dev/null 2>&1
ck "S4.4 raw: a 3000-byte line is byte-exact" \
	"$(sha line3000.in)" "$(sha "$T/d.4.4/R1/stdout")"
rt --pty -D "$T/d.4.5" --timeout 10 --stdin line5000.in --quiet -- "$BB" cat \
	> /dev/null 2>&1
got="$(len "$T/d.4.5/R1/stdout")"
ck "S4.5 cooked: a 5000-byte line is cut by the canonical limit" yes \
	"$([ "$got" -lt 5001 ] && echo yes || echo no)"

# ======================================================= S5 output fidelity
sec "S5 captured bytes are the guest's bytes"
rt -D "$T/d.5.1" --pty --quiet -- "$BB" sh -c 'echo hi' > "$T/o"
ck "S5.1 echo hi is exactly three bytes" "hi|3" \
	"$("$BB" tr '\n' '|' < "$T/o")$(len "$T/o")"
ck "S5.2 no CR in the capture (no ONLCR)" "0" \
	"$("$BB" od -An -v -tu1 < "$T/o" | "$BB" tr -s ' ' '\n' | "$BB" grep -c '^13$')"
rt -D "$T/d.5.4" --pty --quiet -- "$BB" printf 'a\nb\nc\n' > /dev/null 2>&1
ck "S5.3 multi-line output is verbatim" \
	"$(printf 'a\nb\nc')" "$(cat "$T/d.5.4/R1/stdout")"
rt -D "$T/d.5.5" --pty --quiet -- "$BB" cat bin.dat > /dev/null 2>&1
ck "S5.4 binary 4096-byte round trip" "$(sha bin.dat)" "$(sha "$T/d.5.5/R1/stdout")"
"$BB" cmp -s bin.dat "$T/d.5.5/R1/stdout"; ck "S5.5 all 4096 bytes match (cmp)" 0 $?
ck "S5.6 the NUL bytes are still NUL bytes" "16" \
	"$("$BB" od -An -v -tu1 < "$T/d.5.5/R1/stdout" | "$BB" tr -s ' ' '\n' | "$BB" grep -c '^0$')"
"$BB" awk 'BEGIN{for(i=0;i<1200;i++)printf "line %04d of the big file\n",i}' > big.out
rt -D "$T/d.5.8" --pty --quiet -- "$BB" cat big.out > /dev/null 2>&1
ck "S5.7 30 KB output artifact is exact" \
	"$(sha big.out)" "$(sha "$T/d.5.8/R1/stdout")"
rt -D "$T/d.5.9" --pty -- sh -c 'echo one; echo two >&2; echo three' > /dev/null 2>&1
ck "S5.8 merged order is preserved" "one
two
three" "$(cat "$T/d.5.9/R1/stdout")"
rt --pty --quiet -- sh -c 'echo out1; echo err1 >&2' > "$T/o" 2>&1
ck "S5.9 --quiet prints the merged stream on stdout" "out1
err1" "$(cat "$T/o")"
rt --pty --format json -- sh -c 'echo joined' > "$T/o" 2>&1
ck "S5.10 json stdout_view carries the merge" yes \
	"$(has "$(cat "$T/o")" 'joined')"
"$BB" log -D "$T/d.5.9" R1 -l 1:10 > "$T/o" 2>&1
ck "S5.11 log reads the merged artifact back" "1 | one
2 | two
3 | three" "$("$BB" sed -n '2,4p' "$T/o")"
"$BB" log -D "$T/d.5.9" R1 -s stderr > "$T/o" 2>&1
ck "S5.12 merged run: the stderr stream has no lines of its own" "1 | " \
	"$("$BB" sed -n '2,$p' "$T/o" | "$BB" grep ' | ')"

# =========================================================== S6 stdin feed
sec "S6 feeding the guest through its terminal"
rt -D "$T/d.6.1" --pty --stdin forty.in --quiet -- "$BB" cat > /dev/null 2>&1
ck "S6.1 --stdin round trip, trailing newline" \
	"$(sha forty.in)" "$(sha "$T/d.6.1/R1/stdout")"
rt -D "$T/d.6.2" --pty --stdin partial.in --quiet -- "$BB" cat > /dev/null 2>&1
ck "S6.2 --stdin round trip, partial last line" \
	"$(sha partial.in)" "$(sha "$T/d.6.2/R1/stdout")"
rt -D "$T/d.6.3" --pty --stdin /dev/null --quiet -- "$BB" cat > /dev/null 2>&1
ck "S6.3 empty stdin: the guest sees EOF" 0 $?
ck "S6.4 empty stdin: nothing captured" 0 "$(len "$T/d.6.3/R1/stdout")"
"$BB" cat forty.in | "$BB" timeout 30 "$BB" run -D "$T/d.6.5" --pty --quiet \
	-- "$BB" cat > /dev/null 2>&1
ck "S6.5 a piped parent stdin is fed automatically" \
	"$(sha forty.in)" "$(sha "$T/d.6.5/R1/stdout")"
rt --pty --stdin lines.in --quiet -- "$BB" sh -c \
	'n=0; while read -r l; do n=$((n+1)); done; echo $n' > "$T/o" 2>&1
ck "S6.6 40000 lines all arrive" "40000" "$(cat "$T/o")"
rt -D "$T/d.6.7" --pty --stdin lines.in --quiet -- "$BB" cat > /dev/null 2>&1
ck "S6.7 228 KB / 40000-line feed round trip" \
	"$(sha lines.in)" "$(sha "$T/d.6.7/R1/stdout")"
ck "S6.8 fed bytes are not echoed" "$(len lines.in)" "$(len "$T/d.6.7/R1/stdout")"
rt --pty --stdin forty.in --quiet -- "$BB" head -n 2 > "$T/o" 2>&1
ck "S6.9 a guest that exits early does not hang" "1
2" "$(cat "$T/o")"
rt --pty --stdin "$T/missing.in" --quiet -- "$BB" cat > /dev/null 2>"$T/e"
ck "S6.10 missing --stdin file is an error" 126 $?
ck "S6.11 missing --stdin file says which" yes \
	"$(has "$(cat "$T/e")" 'missing.in')"
rt -D "$T/d.6.10" --pty --stdin crlf.in --quiet -- "$BB" cat > /dev/null 2>&1
ck "S6.12 cooked mode maps CR to LF (ICRNL)" \
	"a||b||" "$("$BB" tr '\n' '|' < "$T/d.6.10/R1/stdout")"
rt --pty-raw -D "$T/d.6.11" --stdin line3000.in --quiet -- "$BB" head -c 3001 \
	> /dev/null 2>&1
ck "S6.13 raw mode feeds 3000 bytes byte-exactly" \
	"$(sha line3000.in)" "$(sha "$T/d.6.11/R1/stdout")"
rt -D "$T/d.6.12" --pty-split --stdin forty.in --quiet -- "$BB" cat > /dev/null 2>&1
ck "S6.14 split mode still feeds stdin" \
	"$(sha forty.in)" "$(sha "$T/d.6.12/R1/stdout")"

# ================================================== S7 exit codes, deadline
sec "S7 exit codes and deadline under a pty"
rt --pty --quiet -- sh -c 'exit 0' > /dev/null 2>&1; ck "S7.1 exit 0" 0 $?
rt --pty --quiet -- sh -c 'exit 7' > /dev/null 2>&1; ck "S7.2 exit 7" 7 $?
rt --pty --quiet -- sh -c 'exit 42' > /dev/null 2>&1; ck "S7.3 exit 42" 42 $?
rt --pty --timeout 1 --quiet -- sh -c 'sleep 30' > /dev/null 2>&1
ck "S7.4 --timeout 1 is exit 3" 3 $?
s=$SECONDS
rt --pty --timeout 1 --kill-after 1 --quiet -- sh -c 'trap "" TERM; sleep 30' \
	> /dev/null 2>&1
rc=$?
ck "S7.5 a guest that ignores TERM is still killed" "3" "$rc"
ck "S7.6 ...promptly (under 10s)" yes \
	"$([ $((SECONDS - s)) -lt 10 ] && echo yes || echo no)"
rt --pty --kill-after 0 --timeout 1 --quiet -- sh -c 'sleep 30' > /dev/null 2>&1
ck "S7.7 --kill-after 0 is still exit 3" 3 $?
s=$SECONDS
rt --pty --timeout 20 --quiet -- sh -c 'exit 4' > /dev/null 2>&1
ck "S7.8 a fast guest does not wait for the deadline" yes \
	"$([ $((SECONDS - s)) -lt 10 ] && echo yes || echo no)"
# SIGTERM to the wrapper: cancellation, exit 3, meta records it
rm -f "$T/p.7.8"
"$BB" run --pty --timeout 30 -D "$T/d.7.8" --quiet -- "$BB" sh -c \
	"echo \$\$ > $T/p.7.8; sleep 30" < /dev/null > /dev/null 2>&1 &
w=$!
for _i in $(seq 1 100); do [ -s "$T/p.7.8" ] && break; sleep 0.05; done
kill -TERM "$w" 2>/dev/null
wait "$w" 2>/dev/null; rc=$?
ck "S7.9 SIGTERM to the wrapper cancels (exit 3)" 3 "$rc"
ck "S7.10 ...and meta says cancelled" "1" \
	"$("$BB" sed -n 's/^cancelled=//p' "$T/d.7.8/R1/meta")"
# SIGKILL to the wrapper: the watchdog must take the guest down
rm -f "$T/p.7.9"
"$BB" run --pty -D "$T/d.7.9" --quiet -- "$BB" sh -c \
	"echo \$\$ > $T/p.7.9; exec sleep 30" < /dev/null > /dev/null 2>&1 &
w=$!
for _i in $(seq 1 100); do [ -s "$T/p.7.9" ] && break; sleep 0.05; done
g="$(cat "$T/p.7.9")"
kill -KILL "$w" 2>/dev/null
wait "$w" 2>/dev/null
for _i in $(seq 1 60); do kill -0 "$g" 2>/dev/null || break; sleep 0.05; done
ck "S7.11 SIGKILL of the wrapper releases the guest" "gone" \
	"$(kill -0 "$g" 2>/dev/null && echo alive || echo gone)"
kill -KILL "$g" 2>/dev/null
rt --pty --quiet -- sh -c 'kill -TERM $$; sleep 5' > /dev/null 2>&1
ck "S7.12 a guest killed by a signal is exit 1" 1 $?

# ================================================== S8 environment inheritance
sec "S8 the guest inherits the environment"
PTY_MARK=hello rt --pty --quiet -- "$BB" sh -c 'echo $PTY_MARK' > "$T/o"
ck "S8.1 a parent variable reaches the guest" "hello" "$(cat "$T/o")"
TERM=vt220-x rt --pty --quiet -- "$BB" sh -c 'echo $TERM' > "$T/o"
ck "S8.2 TERM is inherited verbatim" "vt220-x" "$(cat "$T/o")"
rt --pty --quiet -- "$BB" sh -c 'echo ${PATH:+set}' > "$T/o"
ck "S8.3 PATH is inherited" "set" "$(cat "$T/o")"
rt --pty --env PTY_EXTRA=1 --quiet -- "$BB" sh -c 'echo $PTY_EXTRA' > "$T/o"
ck "S8.4 --env sets a variable" "1" "$(cat "$T/o")"
PTY_MARK=parent rt --pty --env PTY_MARK=child --quiet -- "$BB" sh -c \
	'echo $PTY_MARK' > "$T/o"
ck "S8.5 --env overrides an inherited variable" "child" "$(cat "$T/o")"
rt --pty --env PTY_ONCE=1 --quiet -- "$BB" sh -c 'env | grep -c ^PTY_ONCE=' > "$T/o"
ck "S8.6 --env adds the variable once" "1" "$(cat "$T/o")"
"$BB" env | "$BB" sort > env.pipe
"$BB" timeout 30 "$BB" run --pty --quiet -- "$BB" env < /dev/null | "$BB" sort > env.pty
rm -f env.pipe.d env.pty.d
"$BB" grep -v -e '^_=' env.pipe > env.pipe.d 2>/dev/null
"$BB" grep -v -e '^_=' env.pty > env.pty.d 2>/dev/null
ck "S8.7 the environment is identical to a pipe run" "" \
	"$("$BB" diff env.pipe.d env.pty.d 2>&1)"
rt --pty --quiet -- "$BB" sh -c 'echo ${HOME:+home}' > "$T/o"
ck "S8.8 HOME is inherited" "home" "$(cat "$T/o")"
mkdir -p "$T/cwd.d"
rt --pty --cwd "$T/cwd.d" --quiet -- "$BB" sh -c 'pwd' > "$T/o" 2>&1
ck "S8.9 --cwd still works under a pty" \
	"$(cd "$T/cwd.d" && pwd -P)" "$(cd "$(cat "$T/o")" 2>/dev/null && pwd -P)"
rt --pty --env 'PTY_SPACE=a b' --quiet -- "$BB" sh -c 'echo "$PTY_SPACE"' > "$T/o"
ck "S8.10 a value with spaces survives" "a b" "$(cat "$T/o")"

# ================================================ S9 json and meta surface
sec "S9 json and meta describe the terminal"
rt --pty -D "$T/d.9.1" --format json -- sh -c 'true' > "$T/o" 2>&1
j="$(cat "$T/o")"
ck "S9.1 json pty=true" yes "$(has "$j" '"pty":true')"
ck "S9.2 json pty_slave is a device path" yes "$(has "$j" '"pty_slave":"/dev/')"
rt --pty-split --format json -- sh -c 'true' > "$T/o" 2>&1
ck "S9.3 json stderr_merged=false for --pty-split" yes \
	"$(has "$(cat "$T/o")" '"stderr_merged":false')"
rt --pty-raw --format json -- sh -c 'true' > "$T/o" 2>&1
ck "S9.4 json pty_raw=true for --pty-raw" yes \
	"$(has "$(cat "$T/o")" '"pty_raw":true')"
rt --pty --pty-size 100x30 --format json -- sh -c 'true' > "$T/o" 2>&1
ck "S9.5 json reports the requested size" yes \
	"$(has "$(cat "$T/o")" '"pty_cols":100,"pty_rows":30')"
rt --format json -- sh -c 'true' > "$T/o" 2>&1
ck "S9.6 json pty=false without --pty" yes "$(has "$(cat "$T/o")" '"pty":false')"
rt --pty --format json -- sh -c 'echo x' > "$T/o" 2>&1
ck "S9.7 the json is one parseable object" "true" \
	"$("$BB" json -g .pty -t < "$T/o" 2>&1)"
ck "S9.8 meta records pty=1" "1" \
	"$("$BB" sed -n 's/^pty=//p' "$T/d.9.1/R1/meta")"
ck "S9.9 meta records the slave path" yes \
	"$(has "$("$BB" sed -n 's/^pty_slave=//p' "$T/d.9.1/R1/meta")" '/dev/')"
rt -D "$T/d.9.10" --format json -- sh -c 'true' > "$T/o" 2>&1
ck "S9.10 meta records pty=0 without --pty" "0" \
	"$("$BB" sed -n 's/^pty=//p' "$T/d.9.10/R1/meta")"

# ================================================ S10 isolation and hygiene
sec "S10 isolation and hygiene"
# A slave number is reused as soon as a run exits, so "distinct" only means
# anything while all three runs are alive. Each guest therefore parks on its
# terminal until a barrier file appears, which makes the overlap certain
# instead of lucky.
rm -f "$T/go"
for i in 1 2 3; do
	rt --pty --quiet -- "$BB" sh -c "tty > $T/t.$i; while [ ! -f $T/go ]; do sleep 0.02; done" \
		> /dev/null 2>&1 &
done
for _i in $(seq 1 250); do
	set -- "$T/t.1" "$T/t.2" "$T/t.3"
	[ -s "$1" ] && [ -s "$2" ] && [ -s "$3" ] && break
	sleep 0.02
done
: > "$T/go"
wait
ck "S10.1 concurrent runs get distinct slaves" "3" \
	"$("$BB" sort -u "$T/t.1" "$T/t.2" "$T/t.3" | "$BB" wc -l | "$BB" tr -d ' ')"
for i in 1 2 3; do
	k="$i"   # capture now: a background subshell would see the loop's last value
	rt --pty --quiet -- "$BB" sh -c "echo only-$k" > "$T/c.$i" 2>&1 &
done
wait
ck "S10.2 concurrent runs keep their own output" "only-1|only-2|only-3" \
	"$(cat "$T/c.1")|$(cat "$T/c.2")|$(cat "$T/c.3")"
ok=0
for i in $(seq 1 10); do
	rt --pty --quiet -- sh -c 'exit 0' > /dev/null 2>&1 && ok=$((ok + 1))
done
ck "S10.3 ten sequential runs all succeed" 10 "$ok"
rt -D "$T/d.10.4" --pty --quiet -- "$BB" sh -c 'ls /dev/fd | tr "\n" " "' > "$T/o1"
rt -D "$T/d.10.5" --quiet -- "$BB" sh -c 'ls /dev/fd | tr "\n" " "' > "$T/o2"
ck "S10.4 the master fd is not inherited by the guest" \
	"$(cat "$T/o2")" "$(cat "$T/o1")"
nested="$("$BB" timeout 30 "$BB" run --pty --quiet -- "$BB" run --pty --quiet \
	-- "$BB" sh -c 'echo nested-tty' < /dev/null 2>&1)"
ck "S10.5 a pty run inside a pty run" "nested-tty" "$nested"
rt -D "$T/d.10.7" --pty --quiet -- true > /dev/null 2>&1
ck "S10.6 artifacts are private (0600)" "yes" \
	"$(has "$(ls -l "$T/d.10.7/R1/stdout")" 'rw-------')"
"$BB" run --pty -D "$T/d.10.8" --quiet -- "$BB" sh -c \
	"echo \$\$ > $T/p.10.8; sleep 30" < /dev/null > /dev/null 2>&1 &
w=$!
for _i in $(seq 1 100); do [ -s "$T/p.10.8" ] && break; sleep 0.05; done
g="$(cat "$T/p.10.8")"
kill -TERM "$w" 2>/dev/null; wait "$w" 2>/dev/null
for _i in $(seq 1 60); do kill -0 "$g" 2>/dev/null || break; sleep 0.05; done
ck "S10.7 nothing is left running after the wrapper returns" "gone" \
	"$(kill -0 "$g" 2>/dev/null && echo alive || echo gone)"
kill -KILL "$g" 2>/dev/null
rt --pty --timestamps -- sh -c 'echo a; echo b' > "$T/o" 2>&1
ck "S10.8 --timestamps still labels pty output" "2" \
	"$("$BB" grep -c 'out\] ' "$T/o")"
rt --pty --error-ids --format json -- sh -c 'echo "E NOT_FOUND"' > "$T/o" 2>&1
ck "S10.9 --error-ids reads ids from the merged stream" yes \
	"$(has "$(cat "$T/o")" '"codes":["E NOT_FOUND"]')"

# ==================================================== S11 the sh dispatch
sec "S11 sh --pty"
out="$("$BB" timeout 30 "$BB" sh --pty -c '[ -t 1 ] && tty' < /dev/null 2>&1)"
ck "S11.1 sh --pty gives the shell a terminal" "yes" \
	"$(has "$out" '/dev/')"
sizeout="$("$BB" timeout 30 "$BB" sh --pty --pty-size 40x12 -c 'stty size' \
	< /dev/null 2>&1)"
ck "S11.2 sh --pty --pty-size" "12 40" "$sizeout"

# ---------------------------------------------------------------- summary
printf '\n%d/%d checks passed, %d failed\n' "$pass" "$total" "$fail"
if [ "$total" -ne 100 ]; then
	printf 'NOTE: %d checks ran, 100 were planned\n' "$total"
	[ "$fail" -eq 0 ] && exit 1
fi
[ "$fail" -eq 0 ] || exit 1
exit 0
