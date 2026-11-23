---
title: "How run --pty gives a guest a controlling terminal"
kind: "architecture"
summary: "`run --pty` allocates /dev/ptmx, setsids in the child, opens the slave as its controlling terminal and drains the master as a third stream; the env is untouched and the parent's window size is inherited."
tags: [run, sh, pty, tty, setsid, tiocsctty, patch-0008]
created: "2026-11-22T23:36:38.611Z"
updated: "2026-11-22T23:36:38.611Z"
---
`busybox run -Y/--pty` runs the guest under a fresh pty instead of two pipes. The child is a session leader with the slave as its controlling terminal, so `isatty()` is true for 0/1/2, `/dev/tty` resolves, `tty`, `stty` and full-screen tools work; the master is drained exactly like a pipe stream, so all the existing capture, view-budget, deadline and `log` machinery is unchanged. `sh --pty` dispatches the whole shell through `run --pty`, the way `sh --timeout` already dispatches through `run`.

```text
 run --pty -- sh -c '...'
   │
   ├─ open /dev/ptmx → grantpt → unlockpt → ptsname      (pty_alloc)
   ├─ pipe(ready)                                        (handshake)
   ├─ fork
   │    child: close(master); setsid();
   │           fd = open(slave, O_RDWR|O_NOCTTY);
   │           ioctl(fd, TIOCSCTTY, 0);      ← controlling terminal
   │           termios(fd): -ECHO, -ONLCR (or raw), TIOCSWINSZ
   │           dup2(fd,0..2);  write(ready,"1",1)
   │    parent: read(ready) one byte, then pump(master → stdout artifact)
   │            and feed(--stdin|piped stdin → master) with VEOF at the end
   └─ stdout artifact = everything the guest wrote to its terminal, stderr
      merged into it unless --pty-split
```

## Rules that the implementation depends on

- **`setsid()` must come first in the child, and the parent must not `setpgid(pid,pid)`.** `setsid()` fails with `EPERM` for a process-group leader, and the parent's `setpgid` both creates the race and would break it. After `setsid()` the guest's pgid is its pid, so the existing guard `kill(-pid, …)` and the watchdog still reach it.
- **Open the slave after `setsid()`**, or the tty joins the parent's session instead of becoming the guest's terminal. `TIOCSCTTY` is asked for explicitly so this does not depend on open order.
- **One handshake byte** from the child once the slave is configured. Without it the parent can feed stdin into a terminal whose line discipline is still the kernel default (echo on), and the fed bytes come back as echo in the capture. It also tells the parent that a master EOF cannot be expected (the child died before opening the slave).
- **The environment is not touched** — no `TERM`, `PATH` or export is injected; the guest sees exactly what a pipe run sees. Only the window size crosses over: the parent's terminal size if there is one, else 80x24, overridable with `--pty-size`.
- **Termios is set so the capture is the guest's own bytes**: `-ECHO` (no echo of fed stdin) and `-ONLCR` (a pty would otherwise turn every `\n` into `\r\n`, and a pty run of `echo hi` would disagree with a pipe run). `ICANON`/`ISIG` stay on so line readers keep line editing and a real EOF; `--pty-raw` clears all of it.
- **stderr is merged by default** because that is what a terminal is: the guest's `stderr` went to the same slave, so the `stdout` artifact holds both streams in arrival order and the `stderr` artifact is empty. `--pty-split` keeps fd 2 on its own pipe (`isatty(2)` false, `stderr_merged:false` in JSON and meta).
- **libbb's `xgetpty()` is not used**: it dies on failure and falls back to the legacy `/dev/ptyXX` path. `run` opens `/dev/ptmx` itself so it can fail with a clean `SPAWN_FAILED`-style message and no `-lutil` (which `openpty(3)` would add to the static Linux link).

## What a reader should check after touching this

`./tests/pty.sh <binary>` is the contract: 100 checks, and it is expected to be 100/100 on darwin-arm64, darwin-amd64 (Rosetta), linux-arm64 and linux-amd64. `run --pty --format json` reports `pty`, `pty_slave`, `pty_cols`, `pty_rows`, `pty_raw` and `stderr_merged`; `meta` carries the same as `key=value` lines.
