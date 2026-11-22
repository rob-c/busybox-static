---
title: "The stdout diagnostic sweep: `runlevel` was the only one, and `yes` breaks naive sweeps"
kind: "discovery"
summary: "Sweeping every applet with a rejected argument found one stdout diagnostic (runlevel, Linux-only, fixed in patch 0015); `yes` floods a naive sweep and only a non-zero exit makes stdout a violation."
tags: [stderr, stdout, diagnostics, runlevel, testing, sweep, patch-0015]
created: "2026-11-22T19:05:41.146Z"
updated: "2026-11-22T19:05:41.146Z"
---
Sweeping all 388 applets for "does a rejected argument put anything on stdout?" found exactly one violation, and building the sweep itself found two traps worth not repeating: `yes` writes 650 MB before its timeout kills it, and an applet that ignores an unknown argument can legitimately print data, so only a non-zero exit code makes stdout a violation.

## The one violation

`miscutils/runlevel.c` printed `unknown` with `puts()` and returned 1 when it found no `RUN_LVL` record in utmp. Every other applet in the tree already routes diagnostics through `bb_verror_msg`, and `bb_show_usage()` already chooses its stream from `xfunc_error_retval` (`0` → stdout for `--help`, non-zero → stderr for an error). `runlevel` was the single place where a failure produced prose on stdout that a caller cannot distinguish from the applet's data. It is now `bb_simple_error_msg("unknown")`, patch `0015-runlevel-stderr.patch`.

It is only reachable on Linux: Darwin has no utmp, so `runlevel` is not compiled there and the darwin sweep cannot see it. Any future sweep has to run on both platforms or it will miss half the tree.

## The two traps in the sweep

* **`yes` is unbounded.** `yes --nrs-bad-option` ignores the argument and writes forever; with `timeout 2` it emitted 650 MB. Any sweep that captures stdout into a shell variable dies with it (the first version of the script did exactly that). Redirect to a file, test `-s`, and skip `yes` outright. `nologin` behaves the same way.
* **Exit status is the only signal that stdout is a violation.** `arch`, `dirname`, `echo`, `expr`, `printf`, `mount` and `lsof` all ignore the bogus argument, print their normal output and exit 0 — correctly. A sweep that flags any stdout output is useless; the rule has to be "non-zero exit AND non-empty stdout", bounded to `timeout 2` and skipping interpreters, daemons and `resize` (whose stdout is shell code by design).

## A related bug this found on the way

`run --error-ids` appends `BUSYBOX_ERROR_IDS=1` to the child environment, and the child splits each entry with `*eq = '\0'`. Passing a string literal crashed the child with SIGSEGV — `exit_code: -1`, zero bytes captured, and nothing in either artifact to say why. Environment entries must be writable: `xstrdup()`, not `(char *)"..."`. The same trap applies to any future `-e` default.

```text
  sweep rule that works:
    for each applet:
      timeout 2 busybox APPLET --bad-arg </dev/null >OUT 2>/dev/null
      if rc not in {0, 124, 137} and OUT is not empty -> violation
```
