---
title: "`fopen_or_warn_stdin()` is not NULL-safe: branch on argv before calling it"
kind: "gotcha"
summary: "`fopen_or_warn_stdin()` tests `filename[0]` before `filename != NULL`, so a new applet must branch on \"no argument\" and call `fopen_or_warn()`; only a stdin-parity test catches it."
tags: [libbb, stdin, new-applet, segfault, testing]
created: "2026-11-22T16:45:59.739Z"
updated: "2026-11-22T16:45:59.739Z"
---
In this tree `fopen_or_warn_stdin()` dereferences its argument before testing it, so a new applet that passes the result of `argv`-walking must branch on "no filename" first and call `fopen_or_warn()` for a real file. Same shape as `brief_main`, `json` and `peek`.

```text
  FILE *fopen_or_warn_stdin(const char *filename)   /* libbb */
  {
      FILE *fp = stdin;
      if (filename[0] != '-' || filename[1] != '\0')   /* NULL deref here */
          fp = fopen_or_warn(filename, "r");
      return fp;
  }

  wrong:  fp = fopen_or_warn_stdin(*argv);                 /* *argv == NULL → crash */
  right:  fp = (!*argv || !strcmp(*argv, "-"))
            ? stdin : fopen_or_warn(*argv, "r");
```

## Why it stays hidden

The helper reads as if it accepts NULL, and every test that names a file passes. The crash only appears on the "read stdin" path — `printf 'x\n' | busybox applet` with no arguments — which is exactly the path an agent reaches for first.

## The test that catches it

A stdin-parity case, separate from the file case: `printf 'x\n' | busybox applet` must exit 0 and produce the same body as `busybox applet file`. `tests/brief.sh` §14 does this, and it is the only section that fails if the branch is wrong.

## Related

`xmalloc_fgetline()` is also unusable for byte-exact records: it stops at NUL, so `brief` carries its own `getc` reader. See `docs/gotchas/xmalloc-fgetline-splits-records-at-nul-and-loses-the-byte.md`.
