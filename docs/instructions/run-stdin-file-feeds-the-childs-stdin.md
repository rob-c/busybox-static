---
title: "`run --stdin FILE` feeds the child's stdin (patch 0008)"
kind: "instruction"
summary: "`busybox run --stdin FILE` dup2's the file onto fd 0 in the child (before the --cwd chdir); a missing file exits 126 like a bad --cwd, never 127."
tags: [run, stdin, patch-0008, section-14-1, agent-features]
created: "2026-11-22T15:11:02.226Z"
updated: "2026-11-22T15:11:02.226Z"
---
`busybox run --stdin FILE` puts FILE on the child's stdin, so a command that reads stdin can be driven deterministically from a shell. Part of AGENT-FEATURES §14.1, carried in `patches/0008-agent-ops-run.patch`.

```text
  parent: open(FILE) ──► child: xmove_fd(fd, 0) ──► chdir(--cwd) ──► exec
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

- Option `-i` / `--stdin FILE` joins `getopt32long(argv, "T:k:B:C:D:d:sF:i:", …)`, stored in `opt_stdin`.
- The dup2 happens in the **child, before** the `chdir` for `--cwd`, so a relative `--stdin` resolves against the parent's cwd and the two flags compose.
- A missing file exits **126**, matching a failed `--cwd`; 127 stays reserved for "the command could not be executed" (and `SPAWN_FAILED` covers the wrapper case).

## Regenerating

`run.c` ships in `patches/0008-agent-ops-run.patch` together with `doctor.c`. From inside `src/`: `git diff HEAD -- coreutils/run.c miscutils/doctor.c > ../patches/0008-agent-ops-run.patch`, then `git apply --check -R`. After this change: suite 1299 passed on darwin-arm64, `busybox patchcheck` → checked=14 bad=0.
