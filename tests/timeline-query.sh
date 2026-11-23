#!/bin/bash
# Time-addressed retrieval, the idle deadline, and feature advertisement —
# the §9 items of BUSYBOX-CONTRACT.md that now exist.
#
#   ./tests/timeline-query.sh dist/darwin-arm64/bin/busybox
set -u
BB="${1:?usage: timeline-query.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[ -x "$BB" ] || { echo "not executable: $BB" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"

pass=0 fail=0
ck() {
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); printf 'FAIL %-52s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}
sec() { printf '== %s ==\n' "$1"; }

if ! "$BB" --list | "$BB" grep -qx run; then echo "skip: no agent applets"; exit 0; fi

R=$("$BB" run -t -- "$BB" sh -c 'echo a; sleep 0.15; echo b >&2; sleep 0.15; echo c' |
	sed -n 's/^run=\(R[0-9]*\).*/\1/p')
J() { "$BB" log "$R" "$@" --format json; }

sec "Q1. --since / --until address the timeline by time"
ck "since.keeps_later"   "1" "$(J --stream timeline --since 0.2 | "$BB" grep -c '"events"')"
ck "since.count"         "1" "$(J --stream timeline --since 0.2 | "$BB" sed -n 's/.*"events":\[//; s/\].*//p' | "$BB" grep -o '"n":' | "$BB" wc -l | tr -d ' ')"
ck "until.count"         "1" "$(J --stream timeline --until 0.1 | "$BB" grep -o '"n":' | "$BB" wc -l | tr -d ' ')"
ck "since.events_shape"  "1" "$(J --stream timeline --since 0 | "$BB" grep -c '"us":[0-9]*,"stream":"out"')"
ck "since.text_lines"    "1" "$("$BB" log "$R" --stream timeline --since 0.2 | "$BB" grep -c 'c$')"

sec "Q2. --around-gap finds the silences"
ck "gap.json_array"      "1" "$(J --stream timeline --around-gap 0.1 | "$BB" grep -c '"gaps":\[')"
ck "gap.count"           "2" "$(J --stream timeline --around-gap 0.1 | "$BB" grep -o '"gap_us":' | "$BB" wc -l | tr -d ' ')"
ck "gap.limit"           "1" "$(J --stream timeline --around-gap 0.1 --limit 1 | "$BB" grep -o '"gap_us":' | "$BB" wc -l | tr -d ' ')"
ck "gap.none_when_low"   "0" "$(J --stream timeline --around-gap 5 | "$BB" grep -o '"gap_us":' | "$BB" wc -l | tr -d ' ')"

sec "Q3. --summary is the digest the plugin used to compute"
ck "summary.text"        "1" "$("$BB" log "$R" --summary | "$BB" grep -c '^run=R[0-9]* lines=')"
ck "summary.lines"       "3" "$(J --summary | "$BB" sed -n 's/.*"lines":\([0-9]*\).*/\1/p')"
ck "summary.stderr"      "1" "$(J --summary | "$BB" sed -n 's/.*"stderr_lines":\([0-9]*\).*/\1/p')"
ck "summary.exit"        "0" "$(J --summary | "$BB" sed -n 's/.*"exit_code":\([-0-9]*\).*/\1/p')"
ck "summary.gap"         "1" "$(J --summary | "$BB" grep -c '"longest_gap":{"from_us":[0-9]*,"to_us":[0-9]*,"gap_us":[1-9]')"

sec "Q4. --sample bounds output brief cannot reduce"
ck "sample.head"         "1" "$(J --sample 1 | "$BB" grep -c '"lines":\["a"\]')"
ck "sample.tail"         "1" "$(J --sample 1 | "$BB" grep -c '"tail":\["c"\]')"
ck "sample.omitted"      "0" "$(J --sample 1 | "$BB" sed -n 's/.*"omitted":\([0-9]*\).*/\1/p')"
ck "sample.text_two"     "2" "$("$BB" log "$R" --sample 1 | "$BB" wc -l | tr -d ' ')"

sec "Q5. --diff-timeline compares two runs by shape"
R2=$("$BB" run -t -- "$BB" sh -c 'echo a; echo d' | sed -n 's/^run=\(R[0-9]*\).*/\1/p')
ck "difftl.changed"      "true"  "$("$BB" log --diff-timeline "$R:$R2" --format json | "$BB" sed -n 's/.*"changed":\([a-z]*\).*/\1/p')"
ck "difftl.lines_a_b"    "3"     "$("$BB" log --diff-timeline "$R:$R2" --format json | "$BB" sed -n 's/.*"lines":{"a":\([0-9]*\).*/\1/p')"
ck "difftl.missing_rc"   "1"     "$("$BB" log --diff-timeline "R9999:$R" --format json >/dev/null 2>&1; echo $?)"

sec "Q6. --idle-timeout separates stuck from slow"
S=$SECONDS
"$BB" run --idle-timeout 1 --timeout 30 -- "$BB" sh -c 'echo start; sleep 20' >idle.out 2>&1
ck "idle.silent_rc"      "3" "$?"
ck "idle.elapsed_1s"     "no" "$([ $((SECONDS - S)) -gt 6 ] && echo yes || echo no)"
ck "idle.flag_text"      "1" "$("$BB" grep -c 'idle=true' idle.out)"
ck "idle.output_kept"    "1" "$("$BB" grep -c '^start$' idle.out)"
"$BB" run --idle-timeout 2 --timeout 30 --format json -- "$BB" sh -c 'echo 1; sleep 0.4; echo 2; sleep 0.4; echo 3' |
	"$BB" grep -q '"exit_code":0'
ck "idle.active_completes" "0" "$?"
ck "idle.bad_value"      "2" "$("$BB" run --idle-timeout 0 -- true >/dev/null 2>&1; echo $?)"

sec "Q7. --caps advertises what the build has"
for f in brief timeline pty brief-json error-ids stamp-ns idle-timeout log-query; do
	ck "caps.$f" "1" "$("$BB" --caps --format json | "$BB" grep -c "\"$f\"")"
done

printf '== timeline-query: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
