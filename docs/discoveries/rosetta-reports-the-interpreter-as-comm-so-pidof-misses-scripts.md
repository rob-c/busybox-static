---
title: "Rosetta reports the interpreter as comm, so pidof/killall miss scripts there too"
kind: "discovery"
summary: "Under Rosetta a script's /proc comm is the interpreter, so busybox pidof/killall miss it; the argv[1] fallback that fixes macOS is __APPLE__-only, so test name matching on an applet symlink, not a script."
tags: [rosetta, comm, pidof, killall, docker, procps, linux]
created: "2026-11-21T23:43:46.459Z"
updated: "2026-11-21T23:43:46.459Z"
---
Under Docker's Rosetta emulation the kernel reports the *interpreter* as `comm` for a shell script, not the script name, so busybox `pidof` and `killall` cannot find script processes there — the same condition macOS has. On native aarch64 the same script shows `comm=procftest` and the lookup works.

```text
              /proc/<pid>/comm for  ./procftest   (script: execve("/bin/sh",...) )
  native aarch64 Linux .... procftest   -> pidof procftest = 10       OK
  x86-64 under Rosetta ..... sh         -> pidof procftest = (none)   MISS
  macOS .................... sh         -> matched only by the __APPLE__ fallback
```

The fallback that rescues macOS — match `basename(argv[1])` when `argv[0]` is a known interpreter — lives inside `#if defined(__APPLE__)` in `libbb/find_pid_by_name.c` (`darwin_is_interpreter()`), so the Rosetta case falls through to the upstream comm-only match.

## What this means

- Testing the amd64 binary under Rosetta makes `pidof`/`killall` look broken when they are not; assert on a process whose comm is the binary name (an applet symlink such as `ln -sf $BB ./sleep`) instead of on a script.
- The condition is not Mac-specific in reality: anything whose `comm` differs from the name you look for (a script under an interpreter, Rosetta, and soon any process started via an interpreter shim) is invisible to the comm-only path.
- If the fallback is ever widened past `__APPLE__`, keep it to `basename(argv[1])` only — matching further argv elements is what would let `killall foo` kill `grep foo` (see docs/decisions/darwin-process-matching-argv-not-comm.md).
- Observed on: `almalinux:9` and `ubuntu:26.04` with `--platform linux/amd64` on an M5 Max host (Docker Desktop, Rosetta v1.5.3); absent on the same images run natively as aarch64 and on the AlmaLinux 9.8 / 10.2 / Ubuntu 26.04 aarch64 UTM VMs.
