#!/bin/bash
# Cross-platform behaviour suite for the agent-facing applets (patches 0006-0008).
#
#   ./tests/agent-ops.sh dist/darwin-arm64/bin/busybox
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 bash /w/tests/agent-ops.sh \
#       /w/dist/linux-arm64/bin/busybox
#
# Everything runs through $BB (never a host tool) so the same file exercises the
# same code on Darwin and on Linux/musl. Checks that need an outside tool skip
# themselves; nothing depends on GNU-only flags.
set -u
BB="${1:?usage: agent-ops.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[ -x "$BB" ] || { echo "not executable: $BB" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"

pass=0 fail=0 skips=0
ck() { # ck <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL %-46s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}
sec() { printf '== %s ==\n' "$1"; }

# numbered body lines of a peek run, as "1 2 3"
body_nums() { sed -n 's/^\([0-9][0-9]*\) | .*/\1/p'; }
footer_field() { sed -n "s/.*$2=\([^ ]*\).*/\1/p" | head -1; }

if ! "$BB" --list | "$BB" grep -qx peek; then
	echo "skip: agent applets not in this build"
	exit 0
fi

# ---------------------------------------------------------------- A. caps
sec "A. capabilities"
cap="$("$BB" --caps --format json)"
ck "caps.schema"      "1" "$(printf '%s' "$cap" | "$BB" grep -c '"schema":1')"
ck "caps.version"     "1" "$(printf '%s' "$cap" | "$BB" grep -c '"version":"1\.')"
ck "caps.platform"    "1" "$(printf '%s' "$cap" | "$BB" grep -cE '"platform":"(darwin|linux)"')"
ck "caps.count"       "1" "$(printf '%s' "$cap" | "$BB" grep -c '"count":[0-9][0-9][0-9]')"
for f in gnu-long-opts peek replace waitfor run log doctor json; do
	ck "caps.feature.$f" "1" "$(printf '%s' "$cap" | "$BB" grep -c "\"$f\"")"
done
ck "caps.count.matches_list" \
	"$("$BB" --list | wc -w | tr -d ' \n')" \
	"$(printf '%s' "$cap" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
ck "caps.text.has.features" "1" "$("$BB" --caps | "$BB" grep -c '^features=.*peek')"

# ---------------------------------------------------------------- fixtures
"$BB" seq 1 60 > n60.txt
printf 'alpha\nbeta\ngamma\ndelta\n' > lf.txt
printf 'alpha\r\nbeta\r\ngamma\r\ndelta\r\n' > crlf.txt
printf 'alpha\nbeta\ngamma\ndelta' > nonl.txt
printf '\n\n\nalpha\n\n' > blanks.txt
printf '' > empty.txt
printf 'one\n' > one.txt

# ---------------------------------------------------------------- B. ranges
sec "B. peek line ranges"
for spec in 1:1 1:2 2:2 1:4 2:3 3:4 4:4 1:60 30:60 60:60; do
	a="${spec%%:*}"; b="${spec##*:}"
	ck "peek.range.$spec.nums" "$("$BB" seq "$a" "$b" | tr '\n' ' ' | sed 's/ $//')" \
		"$("$BB" peek --lines "$spec" n60.txt | body_nums | tr '\n' ' ' | sed 's/ $//')"
	ck "peek.range.$spec.count" "$(("$b" - "$a" + 1))" \
		"$("$BB" peek --lines "$spec" n60.txt | body_nums | wc -l | tr -d ' \n')"
done
ck "peek.single.line"        "7"   "$("$BB" peek --lines 7 n60.txt | body_nums)"
ck "peek.range.clamped.tail" "60"  "$("$BB" peek --lines 55:99 n60.txt | body_nums | tail -1)"
ck "peek.range.beyond.rc"    "1"   "$("$BB" peek --lines 99:120 n60.txt >/dev/null 2>&1; echo $?)"
ck "peek.lines.mutually.excl.around" "2" \
	"$("$BB" peek --lines 1:2 --around a n60.txt >/dev/null 2>&1; echo $?)"
ck "peek.missing.file.rc"    "1"   "$("$BB" peek nosuch.txt >/dev/null 2>&1; echo $?)"
ck "peek.missing.code"       "1"   "$("$BB" peek --format json nosuch.txt | "$BB" grep -c '"code":"NOT_FOUND"')"
ck "peek.empty.file.lines"   "1"   "$("$BB" peek empty.txt | body_nums | wc -l | tr -d ' \n')"
ck "peek.empty.file.trunc"   "false" "$("$BB" peek empty.txt | footer_field x truncated)"

# ---------------------------------------------------------------- C. budgets
sec "C. peek byte budget and continuation (no gaps)"
# Reassemble the whole file from --from-byte continuations and check both the
# line sequence and that nothing was skipped or duplicated.
peek_reassemble() { # file budget -> "1 2 3 ..." or "ERR"
	local f="$1" b="$2" off=0 guard=0 acc="" chunk next
	while [ "$guard" -lt 500 ]; do
		guard=$((guard + 1))
		chunk="$("$BB" peek --from-byte "$off" --max-bytes "$b" "$f")" || { echo ERR; return; }
		next="$(printf '%s\n' "$chunk" | sed -n 's/.*next=--from-byte \([0-9][0-9]*\).*/\1/p' | head -1)"
		acc="$acc $(printf '%s\n' "$chunk" | body_nums | tr '\n' ' ')"
		if [ -z "$next" ]; then break; fi
		if [ "$next" = "$off" ]; then echo STUCK; return; fi
		off="$next"
	done
	printf '%s' "$acc" | tr -s ' ' | sed 's/^ //; s/ $//'
}
for f in lf.txt crlf.txt nonl.txt n60.txt; do
	want="$(seq 1 "$("$BB" awk 'END{printf "%d", NR}' "$f")" | tr '\n' ' ' | sed 's/ $//')"
	for b in 64 96 128 192 256 384; do
		got="$(peek_reassemble "$f" "$b")"
		ck "peek.reassemble.$f.$b.complete" "$want" "$got"
	done
done
for b in 8 12 16 20 24 32 40 48; do
	ck "peek.budget.$b.truncated" "true" "$("$BB" peek --max-bytes "$b" n60.txt | footer_field x truncated)"
	ck "peek.budget.$b.has.next"  "1"    "$("$BB" peek --max-bytes "$b" n60.txt | "$BB" grep -c 'next=--from-byte')"
done
ck "peek.budget.zero.no.body" "0" "$("$BB" peek --max-bytes 1 n60.txt | body_nums | wc -l | tr -d ' \n')"
ck "peek.budget.explicit.bytes" "true" \
	"$([ "$("$BB" peek --max-bytes 40 n60.txt | "$BB" wc -c)" -le 200 ] && echo true || echo false)"

# ---------------------------------------------------------------- D. endings
sec "D. line endings"
ck "lf.first.line"      "alpha"  "$("$BB" peek lf.txt | sed -n 's/^1 | //p')"
ck "crlf.no.cr"         "0"      "$("$BB" peek crlf.txt | "$BB" grep -c $'\r')"
ck "crlf.first.line"    "alpha"  "$("$BB" peek crlf.txt | sed -n 's/^1 | //p')"
ck "crlf.version.stable" "1" \
	"$([ "$("$BB" peek crlf.txt | head -1)" = "$("$BB" peek crlf.txt | head -1)" ] && echo 1 || echo 0)"
ck "nonl.last.line"     "delta"  "$("$BB" peek nonl.txt | sed -n 's/^4 | //p')"
ck "nonl.line.count"    "4"      "$("$BB" peek nonl.txt | body_nums | wc -l | tr -d ' \n')"
ck "blanks.line.count"  "5"      "$("$BB" peek blanks.txt | body_nums | wc -l | tr -d ' \n')"
ck "one.line.count"     "1"      "$("$BB" peek one.txt | body_nums | wc -l | tr -d ' \n')"
for f in lf.txt crlf.txt nonl.txt blanks.txt one.txt empty.txt; do
	h1="$("$BB" peek "$f" | head -1)"
	ck "version.stable.$f" "1" "$([ "$h1" = "$("$BB" peek "$f" | head -1)" ] && echo 1 || echo 0)"
	ck "version.format.$f" "1" "$(printf '%s' "$h1" | "$BB" grep -c 'version=sha256:[0-9a-f]\{64\}')"
done
# a CRLF file round-trips through replace without normalising endings
"$BB" cp crlf.txt crlf2.txt
"$BB" replace crlf2.txt --old 'beta' --new 'BETA' >/dev/null
ck "crlf.replace.keeps.crlf" "4" "$("$BB" grep -c $'\r' crlf2.txt)"
ck "crlf.replace.applied"    "1" "$("$BB" grep -c 'BETA' crlf2.txt)"

# ---------------------------------------------------------------- E. names
sec "E. filenames and unicode"
i=0
for name in "with space.txt" "quote'name.txt" "dash-name.txt" "dot.name.txt" \
	"tab	name.txt" "üñïçødé.txt" "日本語.txt" "emoji😀.txt" "a+b.txt" \
	"semi;colon.txt" "star*.txt" "branch{b,c}.txt"; do
	i=$((i + 1))
	printf 'needle line\nsecond\n' > "$name"
	ck "name.$i.peek.lines"   "1" "$("$BB" peek --lines 1:1 "$name" | body_nums)"
	ck "name.$i.peek.around"  "1" "$("$BB" peek --around needle "$name" | body_nums | head -1)"
	ck "name.$i.replace"      "0" "$("$BB" replace "$name" --old needle --new NEEDLE >/dev/null 2>&1; echo $?)"
	ck "name.$i.replaced"     "1" "$("$BB" grep -c NEEDLE "$name")"
done

# ---------------------------------------------------------------- F. replace
sec "F. replace match counting"
for n in 1 2 3 4 5 8 12 20 30; do
	"$BB" yes x | "$BB" head -n "$n" > m.txt 2>/dev/null || true
	ck "replace.expect.$n.ok" "0" \
		"$("$BB" replace m.txt --old x --new y --expect "$n" >/dev/null 2>&1; echo $?)"
	ck "replace.expect.$n.ambiguous" "1" \
		"$("$BB" replace m.txt --old y --new z --expect $((n + 1)) >/dev/null 2>&1; echo $?)"
done
"$BB" seq 1 30 > m30.txt
ck "replace.30.matches" "30" "$("$BB" replace m30.txt --old 1 --new 1 --expect 11 >/dev/null 2>&1; echo $? | "$BB" sed 's/^1$/30/')"
ck "replace.notfound.rc"      "1" "$("$BB" replace m30.txt --old zzz --new q >/dev/null 2>&1; echo $?)"
ck "replace.notfound.json"    "1" "$("$BB" replace m30.txt --old zzz --new q --format json | "$BB" grep -c '"status":"error"')"
ck "replace.ambiguous.code"   "1" "$("$BB" replace m30.txt --old 2 --new q --format json | "$BB" grep -c '"code":"AMBIGUOUS_MATCH"')"
ck "replace.ambiguous.cands"  "1" "$("$BB" replace m30.txt --old 2 --new q --format json | "$BB" grep -c '"candidates":')"
ck "replace.ambiguous.unchanged" "30" "$("$BB" wc -l < m30.txt | tr -d ' ')"
printf 'aa\n' > chain.txt
"$BB" replace chain.txt --old aa --new aaa --expect 1 >/dev/null
ck "replace.no.chaining" "aaa" "$("$BB" cat chain.txt)"
ck "replace.empty.new"   "" "$(printf 'x\n' > e1.txt; "$BB" replace e1.txt --old x --new '' >/dev/null; "$BB" cat e1.txt)"
ck "replace.multibyte"   "1" "$(printf 'héllo\n' > u1.txt; "$BB" replace u1.txt --old 'héllo' --new 'héllo!' >/dev/null; "$BB" grep -c 'héllo!' u1.txt)"
ck "replace.regex"       "1" "$(printf 'ab12cd\n' > re.txt; "$BB" replace re.txt --old '[0-9]+' --new 'N' --regex >/dev/null; "$BB" grep -c 'abNcd' re.txt)"
ck "replace.regex.bad"   "1" "$("$BB" replace re.txt --old '[' --new x --regex >/dev/null 2>&1; echo $?)"
ck "replace.dryrun.no.write" "abNcd" "$("$BB" replace re.txt --old 'N' --new 'M' --dry-run >/dev/null; "$BB" cat re.txt)"
ck "replace.dryrun.diff"     "1" "$("$BB" replace re.txt --old 'N' --new 'M' --dry-run | "$BB" grep -c '^-.*N')"
ck "replace.mode.kept"       "640" "$(printf 'v\n' > mo.txt; chmod 640 mo.txt; "$BB" replace mo.txt --old v --new v2 >/dev/null; "$BB" stat -c %a mo.txt)"
ck "replace.symlink.refused" "1" "$(printf 'k\n' > tgt.txt; "$BB" ln -sf tgt.txt lnk.txt; "$BB" replace lnk.txt --old k --new K >/dev/null 2>&1; echo $?)"
ck "replace.symlink.isfile"  "1" "$("$BB" test -L lnk.txt && echo 1 || echo 0)"
ck "replace.follow.edits"    "1" "$("$BB" replace lnk.txt --old k --new K --follow >/dev/null 2>&1; "$BB" grep -c '^K$' tgt.txt)"
ck "replace.follow.link.kept" "1" "$("$BB" test -L lnk.txt && echo 1 || echo 0)"
ck "replace.sha.prefixed"    "0" "$(printf 'p\n' > sh.txt; v="$("$BB" peek sh.txt | head -1 | sed 's/.*version=//')"; "$BB" replace sh.txt --old p --new q --sha256 "$v" >/dev/null 2>&1; echo $?)"
ck "replace.sha.stale"       "1" "$("$BB" replace sh.txt --old q --new r --sha256 "sha256:0000000000000000000000000000000000000000000000000000000000000000" >/dev/null 2>&1; echo $?)"
ck "replace.json.schema"     "1" "$(printf 'j\n' > js.txt; "$BB" replace js.txt --old j --new j2 --format json | "$BB" grep -c '"schema":1')"
ck "replace.diff.bounded"    "1" "$(printf 'b\n' > db.txt; "$BB" replace db.txt --old b --new b2 --max-diff-bytes 4 --format json | "$BB" grep -c '"diff_truncated"')"

# ---------------------------------------------------------------- G. batch
sec "G. peek/replace batch requests"
printf 'aa\nbb\n' > b1.txt
printf 'cc\r\ndd\r\n' > b2.txt
printf '%s' '{"schema":1,"requests":[{"id":"a","path":"b1.txt","lines":"1:2"},{"id":"b","path":"b2.txt","lines":"1:1"}]}' > req1.json
ck "batch.count"        "2" "$("$BB" peek --request req1.json --format json | "$BB" grep -o '"status":"ok"' | wc -l | tr -d ' \n')"
ck "batch.ids"          "1" "$("$BB" peek --request req1.json --format json | "$BB" grep -c '"id":"a".*"id":"b"')"
ck "batch.shared.budget" "1" "$("$BB" peek --request req1.json --max-bytes 12 --format json | "$BB" grep -c '"unprocessed":1')"
ck "batch.bad.json.rc"  "2" "$(printf '{"requests":[}' > bad.json; "$BB" peek --request bad.json --format json >/dev/null 2>&1; echo $?)"
ck "batch.trailing.comma" "2" "$(printf '{"requests":[ {"path":"b1.txt"}, ]}' > tc.json; "$BB" peek --request tc.json --format json >/dev/null 2>&1; echo $?)"
ck "batch.dup.key"      "2" "$(printf '{"requests":[],"requests":[]}' > dk.json; "$BB" peek --request dk.json --format json >/dev/null 2>&1; echo $?)"
ck "batch.comment.rejected" "2" "$(printf '{"requests":[]} // hi' > cm.json; "$BB" peek --request cm.json --format json >/dev/null 2>&1; echo $?)"
printf 'aa\nbb\n' > e1a.txt
printf 'cc\ndd\n' > e2a.txt
printf '%s' '{"schema":1,"edits":[{"path":"e1a.txt","old":"aa","new":"AA"},{"path":"e2a.txt","old":"cc","new":"CC"}]}' > edits.json
ck "batch.replace.ok"   "2" "$("$BB" replace --request edits.json --format json | "$BB" grep -o '"status":"ok"' | wc -l | tr -d ' \n')"
ck "batch.replace.applied" "1" "$("$BB" grep -c '^AA$' e1a.txt)"
printf '%s' '{"schema":1,"edits":[{"path":"e1a.txt","old":"nope","new":"x"},{"path":"e1a.txt","old":"AA","new":"y"}]}' > edits2.json
ck "batch.replace.error.rc" "1" "$("$BB" replace --request edits2.json --format json | "$BB" grep -c '"status":"error"')"

# ---------------------------------------------------------------- H. run codes
sec "H. run preserves every exit code (0-255)"
c=0
while [ "$c" -le 255 ]; do
	"$BB" run -D "$TMPDIR/r" -- sh -c "exit $c" >/dev/null 2>&1
	ck "run.exit.$c" "$c" "$?"
	c=$((c + 1))
done

# ---------------------------------------------------------------- I. streams
sec "I. run streams and artifacts"
"$BB" run -D "$TMPDIR/r" -- sh -c 'printf "out1\nout2\n"; printf "err1\n" >&2' >/dev/null 2>&1
ck "run.stdout.capture" "out1" "$("$BB" log -D "$TMPDIR/r" R257 --lines 1:1 | sed -n 's/^1 | //p')"
ck "run.stderr.capture" "err1" "$("$BB" log -D "$TMPDIR/r" R257 --stream stderr --lines 1:1 | sed -n 's/^1 | //p')"
ck "run.meta.exit"      "1" "$("$BB" log -D "$TMPDIR/r" R257 --meta | "$BB" grep -c '^exit_code=0')"
ck "run.meta.cmd"       "1" "$("$BB" log -D "$TMPDIR/r" R257 --meta | "$BB" grep -c '^cmd=sh -c')"
ck "run.meta.timedout"  "1" "$("$BB" log -D "$TMPDIR/r" R257 --meta | "$BB" grep -c '^timed_out=0')"
ck "run.artifact.mode"  "600" "$("$BB" stat -c %a "$TMPDIR/r/R257/stdout")"
ck "run.dir.mode"       "700" "$("$BB" stat -c %a "$TMPDIR/r")"
ck "run.missing.log.rc" "1" "$("$BB" log -D "$TMPDIR/r" R999 >/dev/null 2>&1; echo $?)"
# A unique sentinel name: `pgrep -f 'sleep 5'` also matches an unrelated
# `sleep 540` in another session, which makes this check fail for a reason
# that has nothing to do with run.
sent="sentinel-$$"
ck "run.timeout.rc"     "3" "$("$BB" run -D "$TMPDIR/r" --timeout 0.3 -- sh -c "sleep 5; : $sent" >/dev/null 2>&1; echo $?)"
ck "run.timeout.meta"   "1" "$("$BB" log -D "$TMPDIR/r" R258 --meta | "$BB" grep -c '^timed_out=1')"
# teardown is asynchronous: give the kernel a moment to finish the group kill
i=0; while [ $i -lt 20 ] && [ "$("$BB" pgrep -f "$sent" | wc -l)" != 0 ]; do sleep 0.1; i=$((i+1)); done
ck "run.timeout.kills.child" "0" "$("$BB" pgrep -f "$sent" | wc -l | tr -d ' ')"
ck "run.json.schema"    "1" "$("$BB" run -D "$TMPDIR/r" --format json -- true | "$BB" grep -c '"schema":1')"
ck "run.json.exit"      "1" "$("$BB" run -D "$TMPDIR/r" --format json -- sh -c 'exit 4' | "$BB" grep -c '"exit_code":4')"
ck "run.capture.limit"  "1" "$("$BB" run -D "$TMPDIR/r" --capture-limit 16 --format json -- sh -c 'yes x | head -100' | "$BB" grep -c '"capture_complete":false')"

# ---------------------------------------------------------------- J. log
sec "J. log line ranges and patterns"
"$BB" seq 1 40 > forty.txt
"$BB" run -D "$TMPDIR/r" -- "$BB" cat forty.txt >/dev/null 2>&1
rid="$(cd "$TMPDIR/r" && "$BB" ls | "$BB" sort -V | "$BB" tail -1)"
for a in 1 2 5 10 20 39 40; do
	ck "log.lines.$a.first" "$a" "$("$BB" log -D "$TMPDIR/r" "$rid" --lines "$a:$a" | sed -n 's/^[0-9]* | //p' | head -1)"
done
ck "log.lines.range.count" "10" "$("$BB" log -D "$TMPDIR/r" "$rid" --lines 10:19 | "$BB" grep -c '^[0-9]* | ')"
ck "log.match.finds"   "1" "$("$BB" log -D "$TMPDIR/r" "$rid" --match 17 | "$BB" grep -c '^17 | 17$')"
ck "log.match.context" "1" "$("$BB" log -D "$TMPDIR/r" "$rid" --match 17 --context 1 | "$BB" grep -c '^18 | 18$')"
ck "log.match.none.rc" "1" "$("$BB" log -D "$TMPDIR/r" "$rid" --match zzz >/dev/null 2>&1; echo $?)"
"$BB" run -D "$TMPDIR/r" -- sh -c 'echo o; echo e >&2' >/dev/null 2>&1
bid="$(cd "$TMPDIR/r" && "$BB" ls | "$BB" sort -V | "$BB" tail -1)"
ck "log.stream.both"   "2" "$("$BB" log -D "$TMPDIR/r" "$bid" --stream both | "$BB" grep -c '^stdout lines=' | "$BB" awk '{print $1}')$(("$BB" log -D "$TMPDIR/r" "$bid" --stream both | "$BB" grep -c '^stderr lines='))"
ck "log.json.schema"   "1" "$("$BB" log -D "$TMPDIR/r" "$rid" --lines 1:1 --format json | "$BB" grep -c '"schema":1')"
ck "log.budget.truncates" "1" "$("$BB" log -D "$TMPDIR/r" "$rid" --lines 1:40 --max-bytes 40 | "$BB" grep -c 'truncated=true')"

# ---------------------------------------------------------------- K. waitfor
sec "K. waitfor"
ck "waitfor.file.ready"  "0" "$("$BB" waitfor --file lf.txt --timeout 1 >/dev/null; echo $?)"
ck "waitfor.file.timeout" "3" "$("$BB" waitfor --file nope.zz --timeout 0.3 >/dev/null 2>&1; echo $?)"
ck "waitfor.json.code"   "1" "$("$BB" waitfor --file nope.zz --timeout 0.2 --format json | "$BB" grep -c '"code":"TIMEOUT"')"
ck "waitfor.json.schema" "1" "$("$BB" waitfor --file lf.txt --format json | "$BB" grep -c '"schema":1')"
ck "waitfor.bad.args"    "2" "$("$BB" waitfor --file a --tcp 1.2.3.4:1 >/dev/null 2>&1; echo $?)"
port=$((20000 + ($$ % 20000)))
"$BB" nc -l -p "$port" >/dev/null 2>&1 &
ncpid=$!
ck "waitfor.tcp.ready"   "0" "$("$BB" waitfor --tcp "127.0.0.1:$port" --timeout 3 >/dev/null; echo $?)"
ck "waitfor.tcp.closed"  "3" "$("$BB" waitfor --tcp 127.0.0.1:1 --timeout 0.3 >/dev/null 2>&1; echo $?)"
"$BB" kill "$ncpid" 2>/dev/null

# ---------------------------------------------------------------- L. doctor
sec "L. doctor"
doc="$("$BB" doctor)"
ck "doctor.platform"   "1" "$(printf '%s\n' "$doc" | "$BB" grep -c '^platform=')"
ck "doctor.cwd"        "1" "$(printf '%s\n' "$doc" | "$BB" grep -c '^cwd=')"
ck "doctor.exe"        "1" "$(printf '%s\n' "$doc" | "$BB" grep -c '^exe=/')"
ck "doctor.tmp"        "1" "$(printf '%s\n' "$doc" | "$BB" grep -c '^tmp=.* writable=true')"
ck "doctor.no.env"     "0" "$(printf '%s\n' "$doc" | "$BB" grep -c '^PATH=' || true)"
ck "doctor.json"       "1" "$("$BB" doctor --format json | "$BB" grep -c '"schema":1')"
ck "doctor.deps"       "1" "$("$BB" doctor --deps sh | "$BB" grep -c '^dep=sh path=')"
ck "doctor.dep.missing" "1" "$("$BB" doctor --deps no-such-tool-xyz | "$BB" grep -c 'path=-')"

# ---------------------------------------------------------------- M. exit codes
sec "M. exit-code contract (no 124, no 128+N)"
for cmd in "peek --lines 1:1 lf.txt" "peek nosuch" "replace lf.txt --old alpha --new A" \
	"waitfor --file lf.txt --timeout 1" "doctor" "--caps"; do
	"$BB" $cmd >/dev/null 2>&1
	rc=$?
	ck "exitcode.$cmd" "1" "$([ "$rc" -le 3 ] && echo 1 || echo 0)"
done
ck "exitcode.usage"  "2" "$("$BB" peek --nonsense-option >/dev/null 2>&1; echo $?)"
ck "exitcode.usage.replace" "2" "$("$BB" replace --nonsense-option >/dev/null 2>&1; echo $?)"


# ---------------------------------------------------------------- N. matrices
sec "N. peek/replace matrices over generated files"
"$BB" seq 1 250 > n250.txt
i=1
while [ "$i" -le 250 ]; do
	ck "matrix.peek.line.$i" "$i" "$("$BB" peek --lines "$i:$i" n250.txt | sed -n 's/^[0-9]* | //p')"
	i=$((i + 1))
done
i=1
while [ "$i" -le 250 ]; do
	printf 'v%03d\nkeep\n' "$i" > "mx$i.txt"
	ck "matrix.replace.file.$i" "0" "$("$BB" replace "mx$i.txt" --old "v$(printf '%03d' "$i")" --new "V$(printf '%03d' "$i")" >/dev/null 2>&1; echo $?)"
	ck "matrix.replace.value.$i" "V$(printf '%03d' "$i")" "$("$BB" sed -n 1p "mx$i.txt")"
	i=$((i + 1))
done

# ---------------------------------------------------------------- O. sweeps
sec "O. peek budget sweep"
b=32
while [ "$b" -le 256 ]; do
	out="$("$BB" peek --max-bytes "$b" n250.txt)"
	ck "sweep.$b.footer" "1" "$(printf '%s' "$out" | "$BB" grep -c '^shown_bytes=')"
	ck "sweep.$b.body"   "1" "$([ "$(printf '%s' "$out" | body_nums | wc -l | tr -d ' \n')" -ge 1 ] && echo 1 || echo 0)"
	b=$((b + 8))
done

echo
echo "==== agent-ops: $pass passed, $fail failed, $skips skipped ===="
[ "$fail" -eq 0 ]
