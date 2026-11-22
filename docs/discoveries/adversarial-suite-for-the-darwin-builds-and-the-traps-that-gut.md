---
title: "Adversarial suite for the Darwin builds, and the traps that gut it"
kind: "discovery"
summary: "adversarial.sh runs ~1270 hostile-input assertions in ~2 min; read the applet list into an array, use $( ) not ( ), treat 129-192 as signals, and never synthesise args for kill/pkill/shutdown-class applets."
tags: [testing, adversarial, fuzzing, darwin, safety, hush, sort]
created: "2026-11-22T01:07:18.250Z"
updated: "2026-11-22T01:07:18.250Z"
---
`adversarial.sh` is the hostile-input suite for these builds. `stress.sh` asks "is each applet stable"; this one asks "what happens when an *attacker* chooses the input", and it runs in about two minutes.

```text
 ./adversarial.sh dist/darwin-arm64/bin/busybox
 ./adversarial.sh dist/darwin-amd64/bin/busybox "arch -x86_64"

 A every applet x 5 probes   --help, bogus option, 4 KiB random stdin,
                             4 KiB argument, empty argv
 B filenames                 spaces, dashes, quotes, backslash, glob chars,
                             embedded newline/tab, NFD vs NFC, 200-char name
 C format strings            %n, %2000d, escapes, sed/awk format abuse
 D sizes                    1 MiB single line, 200k lines, int64 edges, 60-deep tree
 E symlinks                  loops under find -L / du -L / ls -R
 F archives                  tar ../ member, gzip of 2 MB zeros, base64/uu roundtrip
 G environment               empty env, no HOME, no PATH, bogus TMPDIR, busy cwd
 H Darwin-specific           no /proc, mount/lsblk/ifconfig/route/ip must answer,
                             mutating networking must EPERM as non-root
 I signals / pipes           SIGPIPE producers, closed stdout
 J differentials             sort/sort -n/base64/md5/wc/cut vs the system tools
 K-R                         quoting hazards, boundaries, fuzz roundtrips, sort
                             properties, binary+invalid-UTF-8, races, option
                             parsing, link traversal
```

Current result on `darwin-arm64`: `pass: 1268  fail: 0  hangs: 0  crashes: 0  skipped: 55  known: 1`.

## Three harness traps that silently gut a suite

**A probe can eat the applet list.** `while read a; do ... done < <(applets)` loses entries as soon as one probe reads stdin — it dropped the matrix from 263 applets to 51 while still reporting success. Read the list into an array first.

**`"$(cmd)"` vs `"(cmd)"`.** A plain quoted string is not a command; a suite full of those reports failures that are pure fiction. Every `ck "name" "want" "..."` body must be `$(...)`.

**Exit 255 is not a signal.** Testing `rc >= 128` flags `resize` (which exits 255) as a crash. Signals are 129–192; use that range.

## Never synthesise arguments for these applets

`kill`, `killall`, `killall5`, `pkill`, `pgrep`, `pidof`, `shutdown`, `halt`, `reboot`, `poweroff`, `init`, `su`, `passwd`, `chpasswd`, `crontab`, `rtcwake`, `fdformat`, `hdparm`, `devmem`, `swaplabel`, `chvt`, `fbset`, `lpd`/`lpr`, `inetd`/`tftpd`/`tcpsvd`/`udpsvd`, `mount`/`umount`, `swapon`/`swapoff`, `sysctl` are all excluded from the matrix. A garbage option or a 4 KiB "pattern" handed to `pkill` really does match and signal processes — including the harness's own `timeout` wrapper (observed as a spurious SIGTERM) and, if the pattern is generic enough, the parent shell. **A test suite must not be able to kill the machine it runs on.**

## Findings so far

* `hush` segfaults on `\x03` inside any command substitution — upstream, tracked as `KNOWN` (see the hush gotcha doc).
* `busybox sort` uses byte order; macOS `/usr/bin/sort` honours the locale, so under `LANG=en_GB.UTF-8` they disagree on `aa` vs `AA`. Both agree under `LC_ALL=C`, which is therefore pinned in the differential tests.
* `ifconfig`/`route`/`ip` mutation reaches the right syscall and fails `EPERM` unprivileged, with a distinct message per operation — that distinctness is what makes the paths testable without root.
