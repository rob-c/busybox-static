---
title: "A pty cannot carry one input line longer than MAX_CANON, and the limit differs per platform"
kind: "gotcha"
summary: "A pty truncates stdin lines above MAX_CANON (1024 B macOS, 4096 B Linux) at different points per platform and can swallow the VEOF; use --pty-raw for byte-exact or long-line input."
tags: [pty, max-canon, stdin, darwin, linux, raw]
created: "2026-11-22T23:37:10.730Z"
updated: "2026-11-22T23:37:10.730Z"
---
A pty is a canonical terminal, so stdin is not a byte stream: one input line cannot be longer than the platform's `MAX_CANON` and what happens beyond it is unspecified. Measured with 1023-byte-per-line fixtures through `run --pty --stdin … -- cat`:

| input line | macOS (MAX_CANON 1024) | Linux (MAX_CANON 4096) |
|---|---|---|
| 1023 B + `\n` | 1024 B delivered, byte-exact | same |
| 2000 B + `\n` | 978 B delivered | 978 B delivered |
| 3000 B + `\n` | 1024 B | 1024 B |
| 5000 B + `\n` | 1024 B | 4096 B |
| 3000 B, `--pty-raw` | 3001 B, sha256 identical | same |

```text
   guest reads a LINE ──► line discipline (ICANON)
                            ├── line ≤ MAX_CANON  → delivered whole
                            └── line > MAX_CANON  → excess dropped, VEOF may be
                                                    swallowed → read never returns 0
   --pty-raw               ──► no ICANON at all → bytes pass through, no EOF either
```

So: small lines are exact, big lines are truncated *and* the truncation point is not the same on the two platforms, and the guest can end up waiting for a newline that was swallowed — sometimes without any EOF at all, which is a hang rather than a short read.

## The rule

- Any test or tooling that feeds a pty must use lines comfortably under 1024 bytes, or `--pty-raw`.
- `--pty-raw` (no `ICANON`, no `OPOST`, no `ISIG`) is byte-exact in both directions; it is the mode for binary or long-line input. It cannot deliver an EOF, so pair it with `--timeout` (or a guest that exits by byte count).
- Do not assert an exact byte count for an over-long line in anything meant to run on both platforms — assert "not the full length, and no hang" instead. `tests/pty.sh` S4.5 does exactly that, and S6.13 pins the raw-mode round trip.
