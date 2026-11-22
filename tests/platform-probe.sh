#!/bin/bash
# Emit a normalised, deterministic description of what one busybox binary does.
#
#   ./tests/platform-probe.sh build/deep-darwin/busybox  > /tmp/darwin.probe
#   docker run --rm -v "$PWD:/w:ro" almalinux:9 \
#       bash /w/tests/platform-probe.sh /w/build/deep-linux-arm64/busybox > /tmp/linux.probe
#   diff /tmp/darwin.probe /tmp/linux.probe
#
# One line per probe:
#   <applet> <probe> rc=<n> out=<sha256> err=<first line, spaces as _>
#
# Phase A is safe for every applet: --help, a bad long option, a bad short
# option. Phase B runs a curated set of read-only applets over fixed fixtures
# under a timeout, so nothing can mutate the tree or hang the run.
#
# The point is to make platform differences mechanical instead of anecdotal:
# the same source built twice should answer the same way, and every line that
# differs is either a config gate or a backend that behaves differently.
set -u
BB="${1:?usage: platform-probe.sh /path/to/busybox}"
BB="$(cd "$(dirname "$BB")" && pwd)/$(basename "$BB")"
[ -x "$BB" ] || { echo "not executable: $BB" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1     # cwd is the same on both platforms: this directory

say() { printf '%s\n' "$*"; }

# ---- fixtures (identical on both runs) -----------------------------------
: > empty
printf 'x' > onebyte
printf 'alpha\nbravo\ncharlie\n' > three
printf 'a\nb' > nonl
printf 'a\r\nb\r\n' > crlf
printf 'a\000b\nc\n' > binary
printf 'h\303\251llo\n' > unicode
printf '  a  b  \n\tc\td\n' > spaces
mkdir -p tree/sub
printf 'x\n' > tree/f1
printf 'y\n' > tree/sub/f2
printf 'd1 d2\nd3 d4\n' > table
printf 'alpha\nbravo\nalpha\n' > dup
printf '{"a":{"b":[1,2]},"s":"v"}' > doc.json
printf 'one | true | 0 |\n' > cases.tbl
mkdir -p patches
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n' > patches/0001-a.patch

hash() { "$BB" sha256sum | "$BB" cut -d' ' -f1; }

# probe <applet> <label> <args...>
probe() {
	app=$1; label=$2; shift 2
	"$BB" timeout 5 "$app" "$@" > "$T/o" 2> "$T/e" < /dev/null
	rc=$?
	# normalise: the binary path, the temp dir and timings must not leak in
	"$BB" sed -e "s#$BB#BUSYBOX#g" -e "s#$T#TMP#g" \
		-e 's/[0-9][0-9]*\.[0-9][0-9]*/FLOAT/g' \
		-e 's/[0-9][0-9][0-9][0-9][0-9]*/NUM/g' "$T/o" > "$T/on"
	"$BB" sed -e "s#$BB#BUSYBOX#g" -e "s#$T#TMP#g" \
		-e 's/[0-9][0-9]*\.[0-9][0-9]*/FLOAT/g' \
		-e 's/[0-9][0-9][0-9][0-9][0-9]*/NUM/g' "$T/e" > "$T/en"
	out=$(hash < "$T/on")
	err=$(say "$("$BB" head -1 "$T/en" | "$BB" tr ' ' '_')")
	say "$app $label rc=$rc out=$out err=$err"
}

# ---- phase A: every applet, option surface only ---------------------------
say "# phase A: option surface"
"$BB" --list | "$BB" sort | while read -r app; do
	case "$app" in
	# these change state or need a tty even for --help
	rm|rmdir|mv|cp|ln|chmod|chown|chgrp|dd|mknod|mkfifo|kill|killall5|\
	pkill|reboot|poweroff|halt|init|swapoff|swapon|sync|mount|umount|\
	passwd|su|login|setpriv|envuidgid|setuidgid|chroot|watchdog|crond|\
	crontab|syslogd|klogd|telnetd|ftpd|httpd|inetd|udhcpd|dnsd|runsv|runsvdir|	less|more|vi|ed|telnet|watch|top|script|scriptreplay|chat|microcom|	getty|login|consoles|pscan|rx|ttysize|beep) : ;;
	*)
		probe "$app" help --help
		probe "$app" badlong --nosuch-option-xyz
		probe "$app" badshort -Z
		;;
	esac
done

# ---- phase B: curated read-only behaviour --------------------------------
say "# phase B: behaviour over fixed fixtures"
# applet|label|args
while IFS=';' read -r app label args; do
	[ -z "$app" ] && continue
	# shellcheck disable=SC2086
	probe "$app" "$label" $args
done <<'EOF'
cat;file;three
cat;nofile;nosuchfile
head;n2;-n 2 -q
head;n2file;-n 2 -q three
tail;n1;-n 1 -q
tail;c;-c 3 -q three
wc;l;-l three
wc;lc;-lc -q three
md5sum;file;three
sha256sum;file;three
cksum;file;three
sum;file;three
sort;plain;three
sort;rev;-r three
sort;uniq;-u dup
uniq;count;-c dup
cut;f2;-d ' ' -f 2 table
paste;two;table table
expand;tabs;-t 4 spaces
fold;w4;-w 4 -s three
rev;file;three
nl;file;three
od;tx1;-An -tx1 binary
hexdump;C;-C binary
xxd;file;binary
dd;help;--help
tr;upper;a-z A-Z three
sed;sub;s/a/A/ three
awk;sum;{s+=1} END{print s} three
grep;match;alpha dup
grep;c;-c alpha dup
grep;l;-l alpha three
egrep;match;al.ha dup
fgrep;literal;alpha dup
find;name;-name f1 tree
find;type;-type f -name f1 tree
ls;plain;-1 three
ls;l;-l onebyte
ls;d;-d tree
stat;c;-
du;s;-s tree
du;a;-a tree
df;h;-h /
cmp;same;three three
diff;same;three three
md5;file;three
basename;path;/a/b/c.txt
dirname;path;/a/b/c.txt
realpath;file;three
readlink;help;--help
seq;three;1 3
expr;add;1 + 2
test;eq;1 -eq 1
printf;fmt;%s-%s\n a b
echo;e;-e a\tb
printf;num;%d\n 42
yes;help;--help
true;plain;
false;plain;
nproc;plain;
pwd;plain;
whoami;plain;
id;plain;
uname;s;-s
uname;a;-a
arch;plain;
hostname;plain;
env;plain;
printenv;path;PATH
sleep;zero;0
tee;help;--help
xargs;echo;-n 1 echo
tr;delete;-d a three
comm;help;--help
join;help;--help
split;help;--help
tar;t;-tf patches/0001-a.patch
gzip;help;--help
gunzip;help;--help
zip;help;--help
unzip;help;--help
ps;plain;-o pid,comm
ps;args;-o pid,args
ps;help;--help
pgrep;help;--help
pgrep;x;--help
pgrep;nosuch;-x zzznotthere
pkill;help;--help
pidof;help;--help
killall;help;--help
top;help;--help
vmstat;help;--help
mpstat;help;--help
iostat;help;--help
free;plain;
free;h;-h
uptime;plain;
df;help;--help
mount;help;--help
umount;help;--help
ifconfig;help;--help
route;help;--help
ip;help;--help
lsblk;help;--help
netstat;help;--help
lsof;help;--help
fuser;help;--help
nslookup;help;--help
ping;help;--help
wget;help;--help
nc;help;--help
mktemp;help;--help
mktemp;dry;-u
chmod;help;--help
touch;help;--help
cp;help;--help
ln;help;--help
mkdir;help;--help
ls;help;--help
cat;help;--help
stat;help;--help
du;help;--help
sort;help;--help
grep;help;--help
find;help;--help
sed;help;--help
awk;help;--help
cut;help;--help
tr;help;--help
wc;help;--help
EOF
