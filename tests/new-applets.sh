#!/bin/bash
# mark / log --marks, outline, patchapply — the §9.3, §9.6, §9.7 applets.
set -u
BB="${1:?usage: new-applets.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T" || exit 1
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
pass=0 fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-46s want [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
sec() { printf '== %s ==\n' "$1"; }

"$BB" --list | "$BB" grep -qx mark || { echo "skip: applets absent"; exit 0; }

sec "M. mark and log --marks"
ck "mark.outside_run_prints" "1" "$("$BB" mark phase:x | "$BB" grep -cE '^[0-9]+ phase:x$')"
J=$("$BB" run --format json -- "$BB" sh -c "$BB mark phase:build; sleep 0.1; $BB mark phase:test" 2>/dev/null)
R=$(printf '%s' "$J" | sed -n 's/.*"run":"\(R[0-9]*\)".*/\1/p')
ck "marks.two_recorded" "2" "$("$BB" log "$R" --marks --format json | "$BB" grep -o '"name":' | "$BB" wc -l | tr -d ' ')"
ck "marks.named"        "1" "$("$BB" log "$R" --marks | "$BB" grep -c '^phase:build')"
ck "marks.delta_positive" "1" "$("$BB" log "$R" --marks --format json | "$BB" grep -c '"delta_us":[1-9]')"
ck "marks.none"         "[]" "$("$BB" log R999 --marks --format json | sed -n 's/.*"marks":\(\[[^]]*\]\).*/\1/p')"

sec "O. outline"
printf 'int add(int a)\n{\n}\nclass Foo {\n};\n# Title\n' > o.c
ck "outline.version"   "1" "$("$BB" outline o.c | "$BB" grep -c 'version=sha256:[0-9a-f]\{64\}')"
ck "outline.class"     "1" "$("$BB" outline o.c | "$BB" grep -c ':class:.*Foo')"
ck "outline.heading"   "1" "$("$BB" outline o.c | "$BB" grep -c ':heading:.*Title')"
ck "outline.json"      "1" "$("$BB" outline -f json o.c | "$BB" grep -c '"definitions":\[')"
ck "outline.byte_offset" "1" "$("$BB" outline -f json o.c | "$BB" grep -c '"byte":[0-9]')"
ck "outline.missing_rc" "1" "$("$BB" outline /nope >/dev/null 2>&1; echo $?)"

sec "P. patchapply"
printf 'one\ntwo\nthree\n' > f.txt
printf -- '--- a/f.txt\n+++ b/f.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n' > p.patch
ck "patch.dry_run_ok"  "0" "$("$BB" patchapply -n p.patch >/dev/null 2>&1; echo $?)"
ck "patch.dry_changed_nothing" "two" "$(sed -n 2p f.txt)"
ck "patch.apply_rc"    "0" "$("$BB" patchapply p.patch >/dev/null 2>&1; echo $?)"
ck "patch.applied"     "TWO" "$(sed -n 2p f.txt)"
ck "patch.again_mismatch" "1" "$("$BB" patchapply p.patch >/dev/null 2>&1; echo $?)"
printf 'x\n' > g.txt
printf -- '--- a/g.txt\n+++ b/g.txt\n@@ -1 +1 @@\n-x\n+y\n' > g.patch
ck "patch.stale_refused" "1" "$("$BB" patchapply -c "g.txt=sha256:dead" g.patch >/dev/null 2>&1; echo $?)"
V=$("$BB" peek g.txt --format json | sed -n 's/.*"version":"\(sha256:[0-9a-f]*\)".*/\1/p' | cut -c1-19)
ck "patch.prefix_accepted" "0" "$("$BB" patchapply -c "g.txt=$V" g.patch >/dev/null 2>&1; echo $?)"
ck "patch.prefix_applied"  "y" "$(cat g.txt)"
ck "patch.json"        "1" "$(printf -- '--- a/f.txt\n+++ b/f.txt\n@@ -1 +1 @@\n-one\n+ONE\n' > q.patch; "$BB" patchapply -n -F json q.patch | "$BB" grep -c '"status":"ok"')"
ck "patch.invalid"     "1" "$(printf 'not a diff\n' > b.patch; "$BB" patchapply b.patch >/dev/null 2>&1; echo $?)"

sec "N. patchapply creates, and takes several preconditions"
printf -- '--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+alpha\n+beta\n' > n.patch
ck "patch.create_rc"    "0" "$("$BB" patchapply n.patch >/dev/null 2>&1; echo $?)"
ck "patch.create_body"  "alpha" "$(sed -n 1p new.txt 2>/dev/null)"
ck "patch.create_count" "2" "$(wc -l < new.txt | tr -d ' ')"
printf 'a\n' > h1; printf 'b\n' > h2
V1=$("$BB" peek h1 --format json | sed -n 's/.*"version":"\(sha256:[0-9a-f]*\)".*/\1/p' | cut -c1-19)
V2=$("$BB" peek h2 --format json | sed -n 's/.*"version":"\(sha256:[0-9a-f]*\)".*/\1/p' | cut -c1-19)
printf -- '--- a/h1\n+++ b/h1\n@@ -1 +1 @@\n-a\n+A\n' > two.patch
ck "patch.two_preconditions" "0" "$("$BB" patchapply -c "h1=$V1" -c "h2=$V2" two.patch >/dev/null 2>&1; echo $?)"
ck "patch.two_applied"       "A" "$(cat h1)"
ck "patch.second_stale"      "1" "$("$BB" patchapply -c "h2=sha256:dead" two.patch >/dev/null 2>&1; echo $?)"

sec "O2. outline finds a C definition whose brace is on the next line"
printf 'int add(int a)\n{\n}\nint proto(int a);\n' > fn.c
ck "outline.c_function" "1" "$("$BB" outline fn.c | "$BB" grep -c ':function:.*add')"
ck "outline.c_prototype_skipped" "0" "$("$BB" outline fn.c | "$BB" grep -c 'proto')"

sec "H. the binary documents its own flags"
ck "help.log_since"       "1" "$("$BB" log --help 2>&1 | "$BB" grep -c -- '--since')"
ck "help.log_summary"     "1" "$("$BB" log --help 2>&1 | "$BB" grep -c -- '--summary')"
ck "help.log_marks"       "1" "$("$BB" log --help 2>&1 | "$BB" grep -c -- '--marks')"
ck "help.log_sample"      "1" "$("$BB" log --help 2>&1 | "$BB" grep -c -- '--sample')"
ck "help.log_gap"         "2" "$("$BB" log --help 2>&1 | "$BB" grep -c 'around-gap')"
ck "help.run_stampns"     "1" "$("$BB" run --help 2>&1 | "$BB" grep -c -- '--stamp-ns')"
ck "caps.mark"            "1" "$("$BB" --caps --format json | "$BB" grep -c '\"mark\"')"
ck "caps.outline"         "1" "$("$BB" --caps --format json | "$BB" grep -c '\"outline\"')"
ck "caps.patchapply"      "1" "$("$BB" --caps --format json | "$BB" grep -c '\"patchapply\"')"

printf '== new-applets: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
