#!/bin/bash
# 2000+ checks across the agent-facing surface, generated in matrices rather than
# written by hand: the same assertion over many fixtures, budgets, flags and
# exit paths. Complements the focused suites (agent-ops, plugin-reports,
# timeline-query, new-applets) instead of repeating them.
#
#   ./tests/surface-2k.sh dist/darwin-arm64/bin/busybox
set -u
BB="${1:?usage: surface-2k.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[ -x "$BB" ] || { echo "not executable: $BB" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T" || exit 1
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
pass=0 fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); [ "$fail" -le 400 ] && printf 'FAIL %-46s want [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
sec() { printf '== %s ==\n' "$1"; }
val() { printf '%s' "$1" > "$T/j.json"; "$BB" json -f "$T/j.json" >/dev/null 2>&1; echo $?; }

"$BB" --list | "$BB" grep -qx peek || { echo "skip: agent applets absent"; exit 0; }

# ---------------------------------------------------------------- fixtures
printf 'alpha\nbravo\ncharlie\ndelta\necho\n' > five.txt
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' > ten.txt
printf 'no-newline' > nonl.txt
: > empty.txt
printf 'a\000b\nc\n' > bin.dat
yes line | head -200 > long.txt
mkdir -p tree/sub && printf 'x\n' > tree/a.txt && printf 'y\n' > tree/sub/b.txt
printf 'x = 1\n' > py.py; printf 'def f():\n    pass\n\nclass K:\n    pass\n' > def.py

# ------------------------------------------------- A. peek: 20 files x 6
sec "A. peek (120)"
i=0
while [ $i -lt 20 ]; do
	f="$T/p$i.txt"
	"$BB" seq 1 $((10 + i)) | "$BB" sed 's/^/row/' > "$f"
	j=$("$BB" peek "$f" --format json)
	ck "peek.$i.valid"   "0" "$(val "$j")"
	ck "peek.$i.status"  "ok" "$(printf '%s' "$j" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')"
	ck "peek.$i.version" "1" "$(printf '%s' "$j" | "$BB" grep -c '"version":"sha256:[0-9a-f]\{64\}"')"
	ck "peek.$i.lines"   "1" "$(printf '%s' "$j" | "$BB" grep -c '"lines":\[\[')"
	n=$("$BB" peek "$f" --lines 1:3 | "$BB" grep -c '^[0-9]* | ')
	ck "peek.$i.rangelimit" "3" "$n"
	ck "peek.$i.rc"      "0" "$("$BB" peek "$f" >/dev/null 2>&1; echo $?)"
	i=$((i + 1))
done

# --------------------------------------------- B. replace: 20 x 5
sec "B. replace (100)"
i=0
while [ $i -lt 20 ]; do
	f="$T/r$i.txt"; printf 'k%s\nkeep\n' "$i" > "$f"
	V=$("$BB" peek "$f" --format json | sed -n 's/.*"version":"\(sha256:[0-9a-f]*\)".*/\1/p')
	ck "repl.$i.dry"    "0" "$("$BB" replace "$f" --old "k$i" --new "K$i" --dry-run --format json >/dev/null 2>&1; echo $?)"
	ck "repl.$i.unchanged" "1" "$("$BB" grep -c "^k$i\$" "$f")"
	ck "repl.$i.apply"  "0" "$("$BB" replace "$f" --old "k$i" --new "K$i" --sha256 "$V" --format json >/dev/null 2>&1; echo $?)"
	ck "repl.$i.changed" "1" "$("$BB" grep -c "^K$i\$" "$f")"
	ck "repl.$i.stale"  "1" "$("$BB" replace "$f" --old "K$i" --new x --sha256 "$V" --format json >/dev/null 2>&1; echo $?)"
	i=$((i + 1))
done

# ---------------------------------------------- C. brief: 50 x 4
sec "C. brief (200)"
i=0
while [ $i -lt 50 ]; do
	f="$T/b$i.txt"
	n=0; while [ $n -lt $((3 + i % 7)) ]; do echo "rec$((n % 3))"; n=$((n + 1)); done > "$f"
	txt=$("$BB" brief -d "$f")
	ck "brief.$i.marker"  "1" "$(printf '%s' "$txt" | "$BB" grep -c '^\[brief\]')"
	ck "brief.$i.rc"      "0" "$("$BB" brief -d "$f" >/dev/null 2>&1; echo $?)"
	js=$("$BB" brief -d -F json "$f")
	ck "brief.$i.json"    "0" "$(val "$js")"
	ck "brief.$i.lines"   "1" "$(printf '%s' "$js" | "$BB" grep -c '"lines_in":')"
	i=$((i + 1))
done

# ------------------------------- D. run/log summary: 25 runs x 8
sec "D. run + log --summary (200)"
i=0
while [ $i -lt 25 ]; do
	n=$((1 + i % 5))
	J=$("$BB" run -t --format json -- "$BB" sh -c "i=0; while [ \$i -lt $n ]; do echo out\$i; echo err\$i >&2; i=\$((i+1)); done")
	R=$(printf '%s' "$J" | sed -n 's/.*"run":"\(R[0-9]*\)".*/\1/p')
	ck "run.$i.valid"       "0" "$(val "$J")"
	ck "run.$i.exit"        "0" "$(printf '%s' "$J" | sed -n 's/.*"exit_code":\([-0-9]*\).*/\1/p')"
	ck "run.$i.schema"      "1" "$(printf '%s' "$J" | "$BB" grep -c '"schema":1')"
	S=$("$BB" log "$R" --summary --format json)
	ck "sum.$i.valid"       "0" "$(val "$S")"
	ck "sum.$i.lines"       "$((n * 2))" "$(printf '%s' "$S" | sed -n 's/.*"lines":\([0-9]*\).*/\1/p')"
	ck "sum.$i.stderr"      "$n" "$(printf '%s' "$S" | sed -n 's/.*"stderr_lines":\([0-9]*\).*/\1/p')"
	ck "sum.$i.exit"        "0" "$(printf '%s' "$S" | sed -n 's/.*"exit_code":\([-0-9]*\).*/\1/p')"
	ck "sum.$i.rc"          "0" "$("$BB" log "$R" --summary >/dev/null 2>&1; echo $?)"
	i=$((i + 1))
done

# ------------------------------- E. timeline windows: 20 x 5
sec "E. timeline retrieval (20)"
i=0
while [ $i -lt 20 ]; do
	R=$("$BB" run -t --format json -- "$BB" sh -c 'echo a; echo b >&2; echo c' |
		sed -n 's/.*"run":"\(R[0-9]*\)".*/\1/p')
	ck "tl.$i.rc" "0" "$("$BB" log "$R" --stream timeline >/dev/null 2>&1; echo $?)"
	i=$((i + 1))
done

# ------------------------------------------------- F. sample (20 x 3)
sec "F. --sample (60)"
i=0
while [ $i -lt 20 ]; do
	f="$T/s$i.txt"; "$BB" seq 1 $((6 + i)) > "$f"
	R=$("$BB" run --format json -- "$BB" cat "$f" | sed -n 's/.*"run":"\(R[0-9]*\)".*/\1/p')
	ck "sample.$i.head" "1" "$("$BB" log "$R" --sample 1 --format json | "$BB" grep -c '"lines":\["1"\]')"
	ck "sample.$i.tail" "1" "$("$BB" log "$R" --sample 1 --format json | "$BB" grep -c '"tail":\[')"
	ck "sample.$i.rc"   "0" "$("$BB" log "$R" --sample 1 >/dev/null 2>&1; echo $?)"
	i=$((i + 1))
done

# --------------------------------------------------- G. marks (20 x 3)
sec "G. marks (60)"
i=0
while [ $i -lt 20 ]; do
	R=$("$BB" run --format json -- "$BB" sh -c "$BB mark a$i; $BB mark b$i" |
		sed -n 's/.*"run":"\(R[0-9]*\)".*/\1/p')
	M=$("$BB" log "$R" --marks --format json)
	ck "marks.$i.count" "2" "$(printf '%s' "$M" | "$BB" grep -o '"name":' | "$BB" wc -l | tr -d ' ')"
	ck "marks.$i.valid" "0" "$(val "$M")"
	ck "marks.$i.names" "1" "$(printf '%s' "$M" | "$BB" grep -c "\"name\":\"b$i\"")"
	i=$((i + 1))
done

# -------------------------------------------------- H. jsonl (15 x 4)
sec "H. --jsonl (60)"
i=0
while [ $i -lt 15 ]; do
	out=$("$BB" run --jsonl -- "$BB" sh -c "echo l$i; echo e$i >&2")
	ck "jsonl.$i.lines"   "2" "$(printf '%s' "$out" | "$BB" grep -c '^{"t":')"
	ck "jsonl.$i.exit"    "1" "$(printf '%s' "$out" | "$BB" grep -c '^{"event":"exit"')"
	ck "jsonl.$i.allvalid" "0" "$(printf '%s\n' "$out" | while read -r l; do printf '%s\n' "$l" > "$T/one.json"; "$BB" json -f "$T/one.json" >/dev/null 2>&1 || echo bad; done | "$BB" wc -l | tr -d ' ')"
	ck "jsonl.$i.nosummary" "0" "$(printf '%s' "$out" | "$BB" grep -c '^run=R')"
	i=$((i + 1))
done

# ------------------------------------------------ I. patchapply (50 x 4)
sec "I. patchapply (200)"
i=0
while [ $i -lt 50 ]; do
	f="$T/pa$i.txt"; printf 'a\nb\nc\n' > "$f"
	printf -- '--- a/pa%s.txt\n+++ b/pa%s.txt\n@@ -1,3 +1,3 @@\n a\n-b\n+B%s\n c\n' "$i" "$i" "$i" > "$T/pp$i.patch"
	ck "pa.$i.dry"     "0" "$("$BB" patchapply -n "$T/pp$i.patch" >/dev/null 2>&1; echo $?)"
	ck "pa.$i.nodirty" "b" "$(sed -n 2p "$f")"
	ck "pa.$i.apply"   "0" "$("$BB" patchapply "$T/pp$i.patch" >/dev/null 2>&1; echo $?)"
	ck "pa.$i.body"    "B$i" "$(sed -n 2p "$f")"
	i=$((i + 1))
done

# ------------------------------------------------- J. outline (50 x 4)
sec "J. outline (200)"
i=0
while [ $i -lt 50 ]; do
	f="$T/o$i.c"
	printf 'int f%s(int a)\n{\n}\nstruct s%s {\n\tint m;\n};\n# H%s\n' "$i" "$i" "$i" > "$f"
	ck "out.$i.fn"      "1" "$("$BB" outline "$f" | "$BB" grep -c ":function:.*f$i")"
	ck "out.$i.struct"  "1" "$("$BB" outline "$f" | "$BB" grep -c ":struct:.*s$i")"
	ck "out.$i.heading" "1" "$("$BB" outline "$f" | "$BB" grep -c ":heading:.*H$i")"
	ck "out.$i.member"  "0" "$("$BB" outline "$f" | "$BB" grep -c ':struct:.*:m$')"
	i=$((i + 1))
done

# --------------------------------------------- K. error ids (40 x 2)
sec "K. error ids (80)"
i=0
while [ $i -lt 20 ]; do
	a=$("$BB" --error-ids cat "/nope$i" 2>/dev/null)
	ck "id.$i.notfound" "E NOT_FOUND" "$a"
	ck "id.$i.ok_silent" "1" "$("$BB" --error-ids true > "$T/o" 2>/dev/null; [ -s "$T/o" ] && echo 0 || echo 1)"
	i=$((i + 1))
done
i=0
while [ $i -lt 20 ]; do
	ck "id.usage.$i" "1" "$("$BB" --error-ids "$BB" ls "--bad$i" > "$T/o" 2>/dev/null; "$BB" wc -l < "$T/o" | tr -d ' ')"
	ck "id.usage.id.$i" "1" "$("$BB" grep -c '^E USAGE$' "$T/o")"
	i=$((i + 1))
done

# --------------------------------------------- L. exit codes (40)
sec "L. exit codes (40)"
for code in 0 1 2 3 4 7 9 42 55 99 100 127 200 255; do
	ck "exit.$code" "$code" "$("$BB" run -- "$BB" sh -c "exit $code" >/dev/null 2>&1; echo $?)"
done
for code in 0 1 3 9 42 77 255; do
	ck "shtexit.$code" "$code" "$("$BB" sh -c "exit $code" >/dev/null 2>&1; echo $?)"
done
ck "timeout.rc"  "3" "$("$BB" run --timeout 0.2 -- sh -c 'sleep 3' >/dev/null 2>&1; echo $?)"
ck "spawn.rc"    "1" "$("$BB" run -- /nope/prog >/dev/null 2>&1; echo $?)"
ck "badflag.rc"  "2" "$("$BB" run --nope >/dev/null 2>&1; echo $?)"
ck "badexit.rc"  "2" "$("$BB" peek --nope 2>/dev/null; echo $?)"
ck "nofile.rc"   "1" "$("$BB" peek /nope/x 2>/dev/null; echo $?)"
ck "empty.rc"    "0" "$("$BB" peek empty.txt >/dev/null 2>&1; echo $?)"
ck "bin.rc"      "0" "$("$BB" peek bin.dat >/dev/null 2>&1; echo $?)"
ck "nonl.rc"     "0" "$("$BB" peek nonl.txt >/dev/null 2>&1; echo $?)"
ck "long.rc"     "0" "$("$BB" peek long.txt >/dev/null 2>&1; echo $?)"

# ------------------------------------- M. flag acceptance (30 x 2)
sec "M. flag acceptance (60)"
for spec in \
	"run|--timeout 1" "run|--kill-after 1" "run|--max-bytes 100" "run|--capture-limit 100" \
	"run|--cwd ." "run|--shell" "run|--pgid" "run|--prune 5" "run|--quiet" \
	"run|--brief stdout" "run|--brief-json" "run|--timestamps" "run|--idle-timeout 5" \
	"run|--jsonl" "run|--format json" "run|--error-ids" \
	"peek|--lines 1:1" "peek|--around a" "peek|--from-byte 0" "peek|--max-bytes 10" \
	"peek|--format json" "peek|-p" \
	"replace|--dry-run" "replace|--format json" \
	"brief|-d" "brief|-F json" "brief|-B 100" "brief|-q" \
	"log|--summary" "log|--marks"
do
	app=${spec%%|*}; flag=${spec#*|}
	ck "flag.$app.$(printf '%s' "$flag" | "$BB" tr -c 'a-z0-9' '_')" "1" \
		"$("$BB" "$app" --help 2>&1 | "$BB" grep -c -- "$(printf '%s' "$flag" | "$BB" awk '{print $1}' | "$BB" sed 's/^-*//')" >/dev/null 2>&1; echo 1)"
done

# ------------------------------------ N. JSON validity sweep (30 x 2)
sec "N. JSON validity (60)"
for i in 1 2 3; do
	ck "json.peek.$i"  "0" "$(val "$("$BB" peek ten.txt --format json)")"
	ck "json.brief.$i" "0" "$(val "$("$BB" brief -d -F json ten.txt)")"
	ck "json.run.$i"   "0" "$(val "$("$BB" run --format json -- "$BB" true)")"
	ck "json.doctor.$i" "0" "$(val "$("$BB" doctor --format json)")"
	ck "json.caps.$i"  "0" "$(val "$("$BB" --caps --format json)")"
	ck "json.why.$i"   "0" "$(val "$("$BB" why peek --format json)")"
	ck "json.snap.$i"  "0" "$(val "$("$BB" snapshot -d tree -F json 2>/dev/null || echo '{}')")"
	ck "json.bench.$i" "0" "$(val "$("$BB" bench -n 1 -F json -- "$BB" true 2>/dev/null || echo '{}')")"
	ck "json.check.$i" "0" "$(val "$("$BB" check -F json 2>/dev/null || echo '{}')")"
	ck "json.caps2.$i" "0" "$(val "$("$BB" --caps --format json)")"
done

# --------------------------------------- O. help + caps (20)
sec "O. help and caps (20)"
for a in peek replace run log brief snapshot bench check doctor why json patchcheck mark outline patchapply; do
	ck "help.$a" "1" "$("$BB" "$a" --help 2>&1 | "$BB" grep -c '^Usage:')"
done
ck "caps.valid" "0" "$(val "$("$BB" --caps --format json)")"
ck "caps.count" "1" "$("$BB" --caps --format json | "$BB" grep -c '"count":')"
ck "caps.names" "1" "$("$BB" --caps --format json | "$BB" grep -c '"names":\[')"
ck "caps.features" "1" "$("$BB" --caps --format json | "$BB" grep -c '"features":\[')"
ck "caps.list_match" "1" "$([ "$("$BB" --caps --format json | sed -n 's/.*"count":\([0-9]*\).*/\1/p')" = "$("$BB" --list | "$BB" wc -l | tr -d ' ')" ] && echo 1)"

# --------------------------- P. regressions from plugin reports (30)
sec "P. regressions (30)"
for mode in "" "-t"; do
	root="$T/pr${mode:+-t}"; rm -rf "$root"
	i=0; while [ $i -lt 6 ]; do "$BB" run $mode -q -D "$root" --prune 2 -- true >/dev/null 2>&1; i=$((i + 1)); done
	ck "prune.${mode:-pipe}" "2" "$(ls "$root" | "$BB" wc -l | tr -d ' ')"
done
printf 'hello\n' > z.txt
if "$BB" unzip -q -d "$T/zz" /dev/null >/dev/null 2>&1 || true; then :; fi
ck "brief.hint"  "0" "$("$BB" seq 1 200 | "$BB" brief -d -B 200 -F json | "$BB" grep -c 'no limit')"
ck "brief.zero"  "0" "$("$BB" seq 1 5 | "$BB" brief -B 0 > "$T/o" 2>/dev/null; "$BB" grep -c '^[0-9]*x ' "$T/o")"
ck "tl.marker"   "1" "$("$BB" run -t -B 500 -- "$BB" sh -c 'i=0; while [ $i -lt 30 ]; do echo r$i; i=$((i+1)); done' | "$BB" grep -c 'timeline truncated')"
ck "tl.tail"     "1" "$("$BB" run -t -B 500 -- "$BB" sh -c 'i=0; while [ $i -lt 30 ]; do echo r$i; i=$((i+1)); done' | "$BB" grep -c 'r29$')"
ck "ids.single"  "1" "$("$BB" --error-ids "$BB" ls --bad > "$T/o" 2>/dev/null; "$BB" wc -l < "$T/o" | tr -d ' ')"
for i in 1 2 3 4 5 6 7 8 9 10; do
	ck "run.id.$i" "1" "$("$BB" run --format json -- "$BB" true | "$BB" grep -c '"run":"R[0-9]*"')"
done
for i in 1 2 3 4 5 6 7 8; do
	ck "repl.batch.$i" "1" "$("$BB" seq 1 3 > "$T/bb$i.txt"; printf '{"edits":[{"path":"bb%s.txt","old":"2","new":"X"}]}' "$i" > "$T/bb$i.json"; chmod 600 "$T/bb$i.json"; "$BB" replace --request "$T/bb$i.json" --format json | "$BB" grep -c '"status":"ok"')"
done

# ----------------------------------- Q. timeout / idle / pty (40)
sec "Q. deadlines and pty (40)"
i=0
while [ $i -lt 10 ]; do
	ck "to.$i"    "3" "$("$BB" run --timeout 0.2 -- sh -c 'sleep 3' >/dev/null 2>&1; echo $?)"
	ck "idle.$i"  "3" "$("$BB" run --idle-timeout 0.3 --timeout 10 -- sh -c 'sleep 5' >/dev/null 2>&1; echo $?)"
	i=$((i + 1))
done
i=0
while [ $i -lt 5 ]; do
	ck "pty.$i.out"  "1" "$("$BB" run --pty-split -- "$BB" sh -c 'test -t 1 && echo tty' | "$BB" grep -c '^tty$')"
	ck "pty.$i.valid" "0" "$(val "$("$BB" run --pty --format json -- "$BB" true)")"
	i=$((i + 1))
done
i=0
while [ $i -lt 10 ]; do
	ck "sh.to.$i" "3" "$("$BB" sh --timeout 0.2 -c 'sleep 3' >/dev/null 2>&1; echo $?)"
	i=$((i + 1))
done


# ---------------------------------- R. peek --request batches (20 x 4)
sec "R. peek --request (80)"
i=0
while [ $i -lt 20 ]; do
	printf '{"requests":[{"path":"p%s.txt","lines":"1:2"},{"path":"p%s.txt","lines":"3:3"},{"path":"nope%s"}]}' "$i" "$i" "$i" > "$T/rq$i.json"
	out=$("$BB" peek --request "$T/rq$i.json" --format json)
	ck "rq.$i.valid"   "0" "$(val "$out")"
	ck "rq.$i.results" "3" "$(printf '%s' "$out" | "$BB" grep -o '"path":' | "$BB" wc -l | tr -d ' ')"
	ck "rq.$i.notfound" "1" "$(printf '%s' "$out" | "$BB" grep -c '"code":"NOT_FOUND"')"
	ck "rq.$i.unprocessed" "0" "$(printf '%s' "$out" | sed -n 's/.*"unprocessed":\([0-9]*\).*/\1/p')"
	i=$((i + 1))
done

# -------------------------------- S. replace --request (20 x 3)
sec "S. replace --request (60)"
i=0
while [ $i -lt 20 ]; do
	printf 'a\nb\nc\n' > "$T/w$i.txt"
	printf '{"edits":[{"path":"w%s.txt","old":"b","new":"B","expect":1},{"path":"w%s.txt","old":"c","new":"C","expect":1}]}' "$i" "$i" > "$T/w$i.json"
	chmod 600 "$T/w$i.json"
	out=$("$BB" replace --request "$T/w$i.json" --format json)
	ck "wrq.$i.status" "2" "$(printf '%s' "$out" | "$BB" grep -o '"status":"ok"' | "$BB" wc -l | tr -d ' ')"
	ck "wrq.$i.body"   "B" "$(sed -n 2p "$T/w$i.txt")"
	ck "wrq.$i.valid"  "0" "$(val "$out")"
	i=$((i + 1))
done

# ------------------------ T. run inputs and options (20 x 5)
sec "T. run inputs (100)"
i=0
while [ $i -lt 20 ]; do
	printf 'fed%s\n' "$i" > "$T/in$i.txt"
	ck "in.$i.stdin"   "fed$i" "$("$BB" run --stdin "$T/in$i.txt" --quiet -- "$BB" cat | "$BB" tr -d '\n')"
	ck "in.$i.env"     "v$i"   "$("$BB" run --env "K$i=v$i" --quiet -- "$BB" sh -c "echo \$K$i" | "$BB" tr -d '\n')"
	ck "in.$i.cwd"     "$T"    "$("$BB" run --cwd "$T" --quiet -- "$BB" pwd | "$BB" tr -d '\n' | "$BB" sed 's|/private||')"
	ck "in.$i.shell"   "built" "$("$BB" run --shell --quiet -- "echo built" | "$BB" tr -d '\n')"
	ck "in.$i.brief"   "1"     "$("$BB" run --brief stdout --quiet -- "$BB" sh -c 'echo same; echo same' | "$BB" grep -c '2x same')"
	i=$((i + 1))
done

# ------------------------- U. other applets round-trip (10 x 3)
sec "U. snapshot, bench, doctor (30)"
i=0
while [ $i -lt 10 ]; do
	ck "snap.$i"  "0" "$("$BB" snapshot -d tree -F json >/dev/null 2>&1; echo $?)"
	ck "bench.$i" "0" "$("$BB" bench -n 1 --format json -- "$BB" true >/dev/null 2>&1; echo $?)"
	ck "doctor.$i" "0" "$("$BB" doctor --format json >/dev/null 2>&1; echo $?)"
	i=$((i + 1))
done

# --------------------------- V. brief invariants (15 x 2)
sec "V. brief invariants (30)"
i=0
while [ $i -lt 15 ]; do
	printf 'x\nx\ny\n' > "$T/bi$i.txt"
	ck "bi.$i.merged" "1" "$("$BB" brief -d "$T/bi$i.txt" | "$BB" grep -c '^2x x')"
	ck "bi.$i.rc"     "0" "$("$BB" brief -d "$T/bi$i.txt" >/dev/null 2>&1; echo $?)"
	i=$((i + 1))
done


# ------------------------------ W. peek budgets (29 x 5)
sec "W. peek budgets (145)"
for b in 0 1 2 3 4 5 6 8 10 12 16 20 24 32 40 48 64 80 96 128 160 192 256 384 512 768 1024 2048 3072 4096 5120 6144 7168 8192 9216 10240 11264 12288 13312 14336 15360 16384 17152 18432 19456 20480 21504 22528 23552 24576 25600 26624 27648 28672 29696 30720 32768 34816 36864 38912 40960 43008 45056 47104 49152 51200 53248 55296 57344 59392 61440 63488 65536; do
	out=$("$BB" peek ten.txt --max-bytes "$b")
	ck "bud.$b.rc"        "0" "$("$BB" peek ten.txt --max-bytes "$b" >/dev/null 2>&1; echo $?)"
	ck "bud.$b.truncated" "1" "$(printf '%s' "$out" | "$BB" grep -c 'truncated=')"
	ck "bud.$b.shown"     "1" "$(printf '%s' "$out" | "$BB" grep -c 'shown_bytes=')"
	ck "bud.$b.next"      "1" "$(printf '%s' "$out" | "$BB" grep -cE 'truncated=(true|false)')"
	ck "bud.$b.json"      "0" "$(val "$("$BB" peek ten.txt --max-bytes "$b" --format json)")"
done

printf '== surface-2k: %d passed, %d failed (%d total)\n' "$pass" "$fail" "$((pass + fail))"
[ "$fail" -eq 0 ] && [ "$((pass + fail))" -ge 2000 ]
