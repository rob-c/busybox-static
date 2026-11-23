---
title: "`run --stdin FILE` feeds the child's stdin (patch 0008)"
kind: "instruction"
summary: "`run --stdin FILE` dup2's the file onto fd 0 in the child (before the --cwd chdir); under --pty the parent feeds it through the master instead; a missing file exits 126, never 127."
tags: [run, stdin, pty, patch-0008, agent-features]
created: "2026-11-22T15:11:02.226Z"
updated: "2026-11-22T23:50:12.256Z"
---
`busybox run --stdin FILE` puts FILE on the child's stdin, so a command that reads stdin can be driven deterministically from a shell. Part of AGENT-FEATURES §14.1, carried in `patches/0008-agent-ops-run.patch`. Under `--pty` the meaning is preserved but the mechanism differs: fd 0 is the guest's terminal, so the file is written through the pty master instead of being dup2'd.

```text
  pipe mode:  parent: open(FILE) ──► child: xmove_fd(fd, 0) ──► chdir(--cwd) ──► exec
  pty mode:   parent: open(FILE, O_RDONLY|O_NONBLOCK) ──► pump writes it to the master
                                                        ──► VEOF (×2 if it ends mid-line)
                              │
                              └─ missing FILE → 126 (like a bad --cwd), never 127
```

```
$ run --stdin in.txt -- sh -c 'cat'
run=R36 exit_code=0 …
$ log -D $TMPDIR/busybox-run R36
stdout lines=1-1
1 | from-file

$ run --stdin /nope -- true
run=R37 exit_code=126 …  stderr: run: open /nope: No such file or directory
```

## How it is wired

- Option `-i` / `--stdin FILE` joins `getopt32long(argv, "T:k:B:C:D:d:sF:i:Pr:b:qjtY", …)`, stored in `opt_stdin`.
- Without `--pty` the dup2 happens in the **child, before** the `chdir` for `--cwd`, so a relative `--stdin` resolves against the parent's cwd and the two flags compose.
- With `--pty` the child never sees the file: the parent opens it `O_NONBLOCK` and feeds the master, so the guest keeps a terminal on fd 0 and still gets an EOF. Byte-exactness is bounded by the terminal's canonical line limit unless `--pty-raw` is used.
- A missing file exits **126** in both modes, matching a failed `--cwd`; 127 stays reserved for "the command could not be executed" (and `SPAWN_FAILED` covers the wrapper case).

## Regenerating

`run.c` ships in `patches/0008-agent-ops-run.patch` together with `doctor.c`. From inside `src/`: `git diff HEAD -- coreutils/run.c miscutils/doctor.c > ../patches/0008-agent-ops-run.patch`, then `git apply --check -R`. After the pty change: `patchcheck` reports 15 patches, bad=0, and `tests/pty.sh` is 100/100 on darwin-arm64, darwin-amd64, linux-arm64 and linux-amd64.
