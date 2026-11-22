---
title: "bb_busybox_exec_path is /proc/self/exe even on Darwin, so re-exec fails there"
kind: "gotcha"
summary: "CONFIG_BUSYBOX_EXEC_PATH is /proc/self/exe on Darwin too, so any execv through it fails there; use _NSGetExecutablePath or an execvp fallback, as run --shell and doctor now do."
tags: [darwin, exec, proc-self-exe, run, doctor, portability]
created: "2026-11-22T03:41:35.845Z"
updated: "2026-11-22T03:41:35.845Z"
---
`CONFIG_BUSYBOX_EXEC_PATH` is `/proc/self/exe` in every target, including the Darwin builds, where that path does not exist. Anything that re-execs the binary through `bb_busybox_exec_path` therefore fails on macOS and must have a fallback or ask dyld directly.

```text
  applet wants to spawn "busybox APPLET" or "busybox sh"
        │
        ├── execv(bb_busybox_exec_path, ...)   linux: works (/proc/self/exe)
        │                                      darwin: ENOENT, always
        └── fallback: execvp("sh"/"wget", ...)  or _NSGetExecutablePath()
```

## Where it shows up

- `run --shell` in `coreutils/run.c` execs `bb_busybox_exec_path` first and falls back to `execvp("sh", ...)`. On macOS the fallback is what actually runs, so `run -s` uses the system shell, not busybox ash.
- `doctor` (`miscutils/doctor.c`) reports the executable path via `_NSGetExecutablePath(NULL, &size)` on Darwin and `realpath("/proc/self/exe")` elsewhere; without that it printed the literal `/proc/self/exe`.
- The `waitfor --http` design avoided the problem entirely by doing its own HTTP GET instead of spawning `wget --spider`.

## Rules

- Do not build a cross-platform feature on `bb_busybox_exec_path` without an `execvp` fallback; on Darwin the first call always fails, and a silent failure looks like "the tool is missing".
- Setting `CONFIG_BUSYBOX_EXEC_PATH` to a real path is not a fix: the Darwin binary may be moved or installed as a symlink farm, so a compile-time path is wrong in a different way. Ask dyld at runtime.
- `FEATURE_SH_STANDALONE` is off in these builds, so applets spawned from a shell are found on `PATH` and are unaffected; the hazard is applet code that execs the multicall binary by absolute path.
