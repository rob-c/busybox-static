---
title: "Feeding stdin to a pty master is not a read-write loop"
kind: "gotcha"
summary: "Feeding stdin to a pty master breaks on four measured facts: Darwin's POLLNVAL for /dev/null, a never-ready fifo, partial writes that must not be overwritten, and poll(0) not meaning \"do nothing\"."
tags: [pty, stdin, poll, darwin, run, eio]
created: "2026-11-22T23:36:49.252Z"
updated: "2026-11-22T23:36:49.252Z"
---
Feeding stdin into a pty master looks like "read stdin, write master" and is not: four platform behaviours turn the naive loop into a hang or silent data loss. All four were measured with `run --pty --stdin` before the loop was restructured.

```text
 poll(feed_fd)  →  read(chunk)  →  write(master)  →  (partial?) keep the rest
      ↑                                                  │
      └── only poll when nothing is pending ──────────────┘
```

## The four facts

1. **Darwin reports `POLLNVAL` for `/dev/null`.** `poll()` returns ready with `revents = 0x20` (POLLNVAL) for a perfectly valid, always-readable fd. Gating the feed read on `POLLIN` therefore *never* reads `/dev/null`, so `run --pty --stdin /dev/null -- cat` hangs instead of feeding EOF. Any readiness event (`revents != 0`) has to count.
2. **A fifo with no writer is never "ready" on Darwin.** `poll()` returns 0 forever while `read()` would return 0 immediately. Opening `--stdin` with `O_NONBLOCK` and reading it *without* waiting for poll is the only way to see that EOF; for the inherited-stdin case (fd 0, blocking) the poll gate must stay.
3. **A partial write must never be overwritten.** A pty's input queue is about a kilobyte; `write(master, 4096 bytes)` succeeds partially. If the loop re-reads the source before the remainder is written, the leftover bytes are silently dropped — and because a regular file is *always* poll-ready, the loop spins: read 4096, write 1024, discard 3072, repeat. Symptom: a 1.2 KB feed arrives as 0 bytes and the guest hangs. Poll the feed source only when nothing is pending.
4. **`rc == 0` from `poll()` is not "skip this iteration".** With the unconditional non-blocking feed, a 100 ms timeout with no stream ready is exactly when the feed must get its turn.

## Why it matters beyond the tests

Every one of these showed up as "the pty hangs", with no error, no output, and a guest that looked healthy. `tests/pty.sh` S6 pins all four: `/dev/null`, a fifo, a 228 KB feed, and a 40 000-line feed whose reply must be `40000`.
