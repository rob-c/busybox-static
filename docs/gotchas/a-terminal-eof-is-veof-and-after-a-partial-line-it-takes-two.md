---
title: "A terminal EOF is VEOF, and after a partial line it takes two"
kind: "gotcha"
summary: "Closing the master gives the guest no EOF; write VEOF instead, and after a partial line write it twice or every line reader hangs forever."
tags: [pty, veof, eof, stdin, run, canonical]
created: "2026-11-22T23:36:49.206Z"
updated: "2026-11-22T23:36:49.206Z"
---
A pty has no half-close: you cannot shut down the write direction of a master, so "input is finished" has to be expressed the way a terminal expresses it — by writing `VEOF` (0x04) into the master. One `VEOF` with an empty line buffer makes the next `read()` on the slave return 0. But if the line buffer still holds a partial line, the first `VEOF` only *delivers* that line (read returns its bytes, no newline) and is consumed doing so; the next read blocks. That is the two-Ctrl-D rule every terminal user knows, and it is not obvious from the code path.

```text
 input ends "…\n"        queue: "…\n"          write ^D  → next read = 0  (EOF)
 input ends "…14"        queue: "…\n14"        write ^D  → read = "14"    (flushed)
                                              write ^D  → next read = 0  (EOF)
                                                        ↑ the second one is the EOF
```

Measured before the fix: `printf 'a\nb\n'` fed through `run --pty --stdin` gave `cat` its bytes and then hung forever; a file ending with `\n` worked. The tell was that the capture held the whole file (the partial line had been delivered) while the guest was still alive.

## The rule

- Track whether the last byte fed ended on a newline; at end of input write one `VEOF` if it did (or if nothing was fed), two if it did not.
- Send nothing under `--pty-raw`: there is no line discipline to carry it, so a raw pty cannot deliver an EOF at all and a reader that waits for one must be given a deadline (`run --pty-raw --timeout N`).
- Extra `VEOF`s are harmless — after the reader exits they simply stay in the buffer.
- Do not "fix" a hanging reader by closing the master: that hangs up the terminal (`EIO`/`POLLHUP`) and loses the tail of the output.

## Related trap in the same code path

If the input contains one line longer than `MAX_CANON`, the line discipline consumes the excess without delivering it, the pending `VEOF` can be swallowed, and the guest may never see EOF — `cat` hangs even though bytes were captured. `--pty-raw` is the byte-exact mode; in cooked mode, always run such a feed under `--timeout`.
