---
title: "The pty suite: 100 checks, four targets, 100/100 or it is a regression"
kind: "instruction"
summary: "`tests/pty.sh` is 100 checks on the guest's terminal; run it on all four targets after any change to run.c/ash.c, expect 100/100 in ~20 s (Mac) or ~7 s (container)."
tags: [tests, pty, cross-platform, docker, run, flaky]
created: "2026-11-22T23:37:32.987Z"
updated: "2026-11-23T00:03:51.762Z"
---
`tests/pty.sh <binary>` is the contract for `run --pty` / `sh --pty`: 100 checks, ~20 s on a Mac and ~7 s in a container, no root needed. It is meant to be run against every build that ships, and the expected result is **100/100** on darwin-arm64, darwin-amd64 (Rosetta), linux-arm64 and linux-amd64. Measured stable over 5, 3, 12 and 5 consecutive runs respectively.

```sh
./tests/pty.sh dist/darwin-arm64/bin/busybox
./tests/pty.sh dist/darwin-amd64/bin/busybox                      # Rosetta
docker run --rm --platform linux/arm64 -v "$PWD:/w:ro" almalinux:9 \
    bash -c 'cp /w/dist/linux-arm64/bin/busybox /tmp/bb && bash /w/tests/pty.sh /tmp/bb'
docker run --rm --platform linux/amd64 -v "$PWD:/w:ro" almalinux:9 \
    bash -c 'cp /w/dist/linux-amd64/bin/busybox /tmp/bb && bash /w/tests/pty.sh /tmp/bb'
```

```text
  tests/pty.sh BB
     ├─ fixtures (seq/head/tr/dd via BB, no host tools)   lines.in, partial.in, bin.dat …
     ├─ S1..S11 ─ one `ck name expected actual` per property, BB timeout on every guest
     └─ summary: "N/100 checks passed, F failed"
            fail == 0  and  N == 100   → exit 0
            otherwise                  → exit 1   (N != 100 alone is a failure)
```

## What the sections pin

| section | checks | what breaks if it fails |
|---|---|---|
| S1 usage | 8 | `--pty-size` validation, unknown options, exit 2 for usage errors |
| S2 terminal identity | 12 | `isatty(0/1/2)`, `/dev/tty`, `stty size`, no echo, no `onlcr`, pgid == pid |
| S3 `--pty-split` | 6 | stderr on its own pipe, `isatty(2)` false, merged-mode `stderr` artifact empty |
| S4 `--pty-raw` | 5 | `-icanon`, no EOF without a deadline, byte-exact 3000-byte line, canonical truncation |
| S5 capture fidelity | 12 | exact bytes, no CR, binary/NUL/high-bit, 30 KB artifact, merge order, `log` |
| S6 stdin feed | 14 | `--stdin`, partial last line, `/dev/null`, piped stdin, 228 KB, 40 000 lines, `ICRNL` |
| S7 exit codes/deadline | 12 | 0/7/42 pass-through, exit 3, TERM-ignoring guest, SIGTERM cancel, SIGKILL reaper |
| S8 environment | 10 | parent vars, `TERM`, `PATH`, `--env` set/override, pty env == pipe env |
| S9 json/meta | 10 | `pty`, `pty_slave`, `pty_cols/rows`, `pty_raw`, `stderr_merged`, `meta` lines |
| S10 isolation | 9 | 3 concurrent runs, 10 sequential, `/dev/fd` unchanged, nesting, 0600 artifacts |
| S11 `sh --pty` | 2 | the shell dispatch and `sh --pty --pty-size` |

## Rules for extending it

- Copy bytes with `$BB` applets, never with host tools: the suite runs on both platforms and inside a minimal container. `sha`/`len`/`has` helpers are at the top for that reason.
- A comparison of two *runs* must use one run: getting a pid from one invocation and the pgid from another compares unrelated processes, and `$i` inside a backgrounded subshell has already advanced.
- **A pty slave number is reused as soon as its run exits**, so "three concurrent runs have three distinct slaves" is only true while the runs overlap. S10.1 parks each guest on its terminal until a barrier file appears; without that barrier the check flaked ~2 runs in 10 on linux-arm64 (the kernel handed the freed number straight back).
- Anything that may legitimately block (a raw-mode reader, an over-long line) must be wrapped in `$BB timeout`, so a wedge fails a check instead of the suite.
- The check count is asserted, so a deleted check cannot pass silently.
