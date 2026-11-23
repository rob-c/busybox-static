---
title: "Plugin-reported busybox defects: prune under -t, unzip -d, and a withdrawn claim"
kind: "gotcha"
summary: "Fixed `--prune` under `-t` (rmdir failed on the timeline file) and `unzip -d DIR` on macOS (BSD getopt stops at the first non-option); the reported `--match` defect was a misreading — context 3 hid the filter working."
tags: [run, unzip, brief, prune, getopt, patch-0004, patch-0008, patch-0014]
created: "2026-11-23T12:02:50.059Z"
updated: "2026-11-23T12:02:50.059Z"
---
Three defects reported by the `pi-managed-tools` side are fixed: `run --prune` under `--timestamps`, `unzip -d DIR` after the archive name, and brief's `-B 0` hint. A fourth claim — `--match` ignored on `log --stream timeline` — was **withdrawn**: it works, and the original report used the default context of 3.

```text
  run -t --prune 5     before: prune unlinked stdout/stderr/meta, rmdir then failed
                       on the extra `timeline` file  ->  10 runs left 10 dirs
                       after:  directory emptied entry by entry -> 5 dirs

  unzip a.zip -d out   before (macOS): BSD getopt stops at the first non-option,
                       so "-d out" became member names -> nothing extracted, exit 0
                       after:  -d peeled from argv wherever it appears

  brief -B 0           hint said "-B 0 for no limit" while 0 is a zero budget
```

## Why unzip differed by platform

`unzip_main()` parses with libc `getopt(argv, "-d:lnotpqxjvK")`. glibc **permutes** argv, so options after the archive are still options; BSD/macOS getopt **stops** at the first non-option, so `-d out` fell into the `case 1:` member-pattern branch. The applet then extracted nothing and exited 0. The fix peels `-d DIR`, `-dDIR` and clustered `-qd DIR` out of argv before parsing, so both implementations see the same argv. Verified: `-d out` before and after the archive, `-dout`, and `-qd out` all extract.

## Why prune missed the timeline

`prune_runs()` unlinked a hard-coded list (`stdout`, `stderr`, `meta`) and then `rmdir()`; a `-t` run also writes `timeline`, so `rmdir` failed with ENOTEMPTY and the directory stayed. It now walks the directory and unlinks every entry, which also survives the next artifact type being added.

## Check the claim before fixing it

The `--match` report was produced with `--match bravo` and no `--context`, so all three lines were context — the filter was working. `--context 0` shows `lines:[[3,3]]`. Fixing that "defect" would have meant changing correct code; the analysis note carries the retraction.

Suites: test.sh 198 · agent-ops 1299 · brief 910 · agent-ops-sweep 1267 · reaper 50 · wrapper-signals 21. `tests/streams.sh` has 2 failures from a separate in-flight error-id change (`verror_msg.c` emits `FAILED` where the test expects `E USAGE`), untouched here.
