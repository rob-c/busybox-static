#!/bin/bash
# Compare two platform-probe dumps and classify every difference.
#
#   ./tests/platform-probe.sh darwin/busybox            > /tmp/darwin.probe
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 \
#       bash /w/tests/platform-probe.sh /w/linux/busybox > /tmp/linux.probe
#   ./tests/platform-diff.sh /tmp/darwin.probe /tmp/linux.probe
#
# Every difference is put in one of five buckets, because they need different
# work:
#
#   usage   the --help text differs  -> the *option surface* differs (config
#           gate, pruned feature, or a platform-only flag)
#   exit    the same command exits differently
#   output  same status, different bytes on stdout
#   stderr  same status, different bytes on stderr
#   timeout one side had to be killed -> not a difference, excluded
#
# Also reports probes that only one side ran at all (an applet present on one
# platform and pruned on the other), which is the applet-set difference seen
# from the option side.
set -u
A="${1:?usage: platform-diff.sh A.probe B.probe}"
B="${2:?usage: platform-diff.sh A.probe B.probe}"
BB="${BB:-busybox}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

"$BB" grep -v '^#' "$A" | "$BB" sort > "$T/a"
"$BB" grep -v '^#' "$B" | "$BB" sort > "$T/b"

# key = applet + probe, so a renamed probe cannot silently pair up wrongly
"$BB" awk '{k=$1" "$2; $1=""; $2=""; print k"|"$0}' "$T/a" > "$T/ak"
"$BB" awk '{k=$1" "$2; $1=""; $2=""; print k"|"$0}' "$T/b" > "$T/bk"

onlya=$( "$BB" join -v 1 -t'|' "$T/ak" "$T/bk" | "$BB" wc -l | "$BB" tr -d ' ' )
onlyb=$( "$BB" join -v 2 -t'|' "$T/ak" "$T/bk" | "$BB" wc -l | "$BB" tr -d ' ' )

"$BB" join -t'|' "$T/ak" "$T/bk" > "$T/both"

rck() { "$BB" sed -n 's/.*rc=\([0-9]*\).*/\1/p'; }
outk() { "$BB" sed -n 's/.*out=\([a-f0-9]*\).*/\1/p'; }
errk() { "$BB" sed -n 's/.*err=\([^ ]*\).*/\1/p'; }

"$BB" awk -F'|' '
function rc(s) { match(s, /rc=[0-9]+/); return substr(s, RSTART+3, RLENGTH-3) }
function out(s) { match(s, /out=[a-f0-9]+/); return substr(s, RSTART+4, RLENGTH-4) }
function err(s) { match(s, /err=.*/); return substr(s, RSTART+4) }
{
	key=$1; a=$2; b=$3
	split(key, p, " ")
	app=p[1]; pr=p[2]
	ra=rc(a); rb=rc(b)
	if (ra == 137 || rb == 137) { skip++; next }
	if (ra != rb) { cls="exit" }
	else if (out(a) != out(b)) { cls="output" }
	else if (err(a) != err(b)) { cls="stderr" }
	else { same++; next }
	# Machine data, not applet behaviour: the same command asked two different
	# computers a question. Keep them visible but in their own bucket.
	if (app ~ /^(hostname|id|whoami|pwd|realpath|uname|uptime|free|df|ps|env|printenv|mktemp|ls|du|stat)$/)
		cls="env"
	if (pr == "help") cls="usage"
	total[cls]++
	app_cls[app]=app_cls[app] " " cls
	line[cls]=line[cls] sprintf("  %-14s %-10s rc=%s/%s\n", app, pr, ra, rb)
}
END {
	printf "compared probes: %d\n", NR
	printf "identical:       %d\n", same
	printf "excluded (timeout on one side): %d\n", skip
	for (c in total) printf "%-8s %d\n", c, total[c]
	printf "\n"
	split("usage exit env output stderr", order, " ")
	for (o in order) {
		c = order[o]
		if (!total[c]) continue
		printf "== %s (%d)\n", c, total[c]
		printf "%s", line[c]
	}
}
' "$T/both"

printf '\nprobes only in A (first file): %s\n' "$onlya"
printf 'probes only in B (second file): %s\n' "$onlyb"
if [ "$onlya" != 0 ] || [ "$onlyb" != 0 ]; then
	printf '%s\n' '-- name-only differences --'
	"$BB" join -v 1 -t'|' "$T/ak" "$T/bk" | "$BB" cut -d'|' -f1 | "$BB" sort -u |
		"$BB" sed 's/^/  only-A /' | "$BB" head -40
	"$BB" join -v 2 -t'|' "$T/ak" "$T/bk" | "$BB" cut -d'|' -f1 | "$BB" sort -u |
		"$BB" sed 's/^/  only-B /' | "$BB" head -40
fi
