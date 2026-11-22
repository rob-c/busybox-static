---
title: "fuser on Darwin, plus two traps: a comment containing */ and self-matching in ash"
kind: "gotcha"
summary: "fuser ported to Darwin via libproc (254 applets); a `*/` inside a comment closes it, and testing fuser from busybox sh proves nothing because the applet runs in the same process."
tags: [fuser, darwin, libproc, comments, testing]
created: "2026-11-21T18:31:41.047Z"
updated: "2026-11-21T18:31:41.047Z"
---
`fuser` now works on Darwin for file arguments, taking the build to **254 applets** (Linux: 410). It reuses the libproc enumeration that `lsof` uses and matches by `dev`/`ino` exactly like the `/proc` version.

```text
 fuser /tmp/target.txt  →  holder pid
   linux:  walk /proc/PID/{cwd,exe,root,fd}, stat each, match dev+ino
   darwin: proc_pidinfo(PROC_PIDLISTFDS) → proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)
           → stat(vip_path) → search_dev_inode()
```

## Two traps

1. **A `*/` inside a comment closes it.** The header comment said `No /proc/*/{cwd,exe,root,fd}` — the `*/` in `proc/*/` terminated the block comment early and the rest became code (`expected identifier or '('` at the comment line). Write `/proc/PID/{...}` instead. This cost a build cycle and is easy to repeat.
2. **Testing `fuser` from `busybox sh -c` proves nothing.** ash runs the applet in the same process, so the descriptor opened by `exec 3<file` then belongs to `fuser` itself, which skips its own pid — a correct "no match". Use an external holder: `sleep 30 < /tmp/target.txt &` then `fuser /tmp/target.txt` printed the holder's pid.

## Limits

PORT/PROTO arguments are not supported: they need `/proc/net/{TCP,UDP}`, and the code now says so (`skipping '22/tcp': PORT/PROTO needs /proc/net`) instead of dying in `xstat`. `-m` (memory-mapped files) has no equivalent either. Everything else — `-k SIGNAL`, `-s`, `-4`/`-6` parsing, multiple file arguments — behaves as on Linux.

Verified: `fuser /dev/null` lists hundreds of pids; a background holder is found and reported; `./test.sh` 168/168 on all five Darwin artifacts, `./stress.sh` 259/0/0/0, six build targets, patch series reproduces `src/`.
