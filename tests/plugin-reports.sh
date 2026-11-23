#!/bin/bash
# Regressions for the defects the pi-managed-tools side reported against this
# build. Each check names the report it guards, so a future change that undoes a
# fix fails with the reason attached.
#
#   ./tests/plugin-reports.sh dist/darwin-arm64/bin/busybox
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 \
#       bash /w/tests/plugin-reports.sh /w/dist/linux-arm64/bin/busybox
set -u
BB="${1:?usage: plugin-reports.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[ -x "$BB" ] || { echo "not executable: $BB" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"

pass=0 fail=0
ck() { # ck <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL %-56s want [%s] got [%s]\n' "$1" "$2" "$3"
	fi
}
sec() { printf '== %s ==\n' "$1"; }

if ! "$BB" --list | "$BB" grep -qx run; then
	echo "skip: agent applets not in this build"
	exit 0
fi

# ---------------------------------------------- R1: prune under --timestamps
sec "R1. run --prune works with and without -t"
for mode in "" "-t"; do
	root="$T/prune${mode:+-t}"
	rm -rf "$root"
	i=0
	while [ "$i" -lt 8 ]; do
		"$BB" run $mode -q -D "$root" --prune 3 -- true >/dev/null 2>&1
		i=$((i + 1))
	done
	ck "prune.${mode:-pipe}.keeps3" "3" "$(ls "$root" | "$BB" wc -l | tr -d ' ')"
done
"$BB" run -t -q -D "$T/prune2" --prune 2 -- true >/dev/null 2>&1
ck "prune.reports_count" "1" "$("$BB" run -t -D "$T/prune2" --prune 2 -- true 2>/dev/null | "$BB" grep -c '^pruned=')"

# ------------------------------------------------------- R2: unzip -d DIR
sec "R2. unzip -d DIR extracts, wherever the option sits"
printf 'hello\n' > f.txt
"$BB" zip -q a.zip f.txt 2>/dev/null || /usr/bin/zip -q a.zip f.txt 2>/dev/null
if [ -s a.zip ]; then
	rm -rf d1 d2 d3 d4
	"$BB" unzip -q a.zip -d d1 >/dev/null 2>&1
	ck "unzip.d_after_archive" "1" "$(ls d1 2>/dev/null | "$BB" wc -l | tr -d ' ')"
	"$BB" unzip -q -d d2 a.zip >/dev/null 2>&1
	ck "unzip.d_before_archive" "1" "$(ls d2 2>/dev/null | "$BB" wc -l | tr -d ' ')"
	"$BB" unzip -q a.zip -dd3 >/dev/null 2>&1
	ck "unzip.d_attached" "1" "$(ls d3 2>/dev/null | "$BB" wc -l | tr -d ' ')"
	"$BB" unzip -qd d4 a.zip >/dev/null 2>&1
	ck "unzip.cluster_qd" "1" "$(ls d4 2>/dev/null | "$BB" wc -l | tr -d ' ')"
	ck "unzip.content_kept" "hello" "$(cat d1/f.txt 2>/dev/null)"
	ck "unzip.list_still_works" "1" "$("$BB" unzip -l a.zip | "$BB" grep -c 'f.txt')"
	"$BB" unzip -qo a.zip -d d1 >/dev/null 2>&1
	ck "unzip.repeat_with_overwrite_ok" "0" "$?"
else
	echo "skip: no zip writer available"
fi

# ------------------------------------------------------ R3: brief -B hint
sec "R3. brief's budget hint matches -B 0"
"$BB" seq 1 200 | "$BB" brief -d -B 200 -F json > b.json 2>/dev/null
ck "brief.hint_no_no_limit" "0" "$("$BB" grep -c 'no limit' b.json)"
ck "brief.hint_names_zero"    "1" "$("$BB" grep -c 'zero budget' b.json)"
"$BB" seq 1 200 | "$BB" brief -d -B 0 > b0.txt 2>/dev/null
ck "brief.zero_budget_shows_nothing" "0" \
	"$("$BB" grep -Ec '^[0-9]+x ' b0.txt)"
ck "brief.zero_budget_exit0" "0" "$("$BB" seq 1 5 | "$BB" brief -B 0 >/dev/null 2>&1; echo $?)"

# ---------------------------------------------- R4: text timeline has a tail
sec "R4. run -t text view keeps head and tail"
"$BB" run -t -B 600 -- "$BB" sh -c 'i=0; while [ $i -lt 40 ]; do echo row$i; i=$((i+1)); done' > tl.txt 2>/dev/null
ck "timeline.marker_present" "1" "$("$BB" grep -c 'timeline truncated' tl.txt)"
ck "timeline.head_kept"      "1" "$("$BB" grep -c 'row0$' tl.txt)"
ck "timeline.tail_kept"      "1" "$("$BB" grep -c 'row39$' tl.txt)"
ck "timeline.marker_between" "1" \
	"$("$BB" awk '/timeline truncated/{m=NR} /row0$/{h=NR} /row39$/{t=NR} END{print (h<m && m<t) ? 1 : 0}' tl.txt)"
ck "timeline.shown_counts_both" "1" \
	"$("$BB" awk '/^timeline_lines=/{split($2,b,"="); print (b[2]+0 > 2) ? 1 : 0}' tl.txt)"
ck "timeline.evidence_complete" "40" \
	"$("$BB" grep -Ec '^\[ *[0-9]+\.[0-9]{6} out\] row[0-9]+$' "$TMPDIR"/busybox-run/R*/timeline | tail -1)"

# ------------------------------------------------- R5: one id per diagnostic
sec "R5. --error-ids: a usage error is exactly one id"
"$BB" --error-ids ls --nrs-bad-option > u.out 2> u.err
ck "ids.usage_one_line"  "1" "$("$BB" wc -l < u.out | tr -d ' ')"
ck "ids.usage_is_USAGE"  "E USAGE" "$(cat u.out)"
ck "ids.message_on_stderr" "1" "$("$BB" grep -c 'unrecognized option' u.err)"
ck "ids.usage_text_on_stderr" "1" "$("$BB" grep -c 'Usage:' u.err)"
"$BB" --error-ids cat /nope > nf.out 2>/dev/null
ck "ids.not_found"       "E NOT_FOUND" "$(cat nf.out)"
"$BB" --error-ids echo hi > ok.out 2>/dev/null
ck "ids.success_silent"  "hi" "$(cat ok.out)"

printf '== plugin-reports: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
