---
title: "`run --env NAME=VALUE` sets the child's environment (patch 0008)"
kind: "instruction"
summary: "`busybox run --env NAME=VALUE` (repeatable) peels pairs off argv before getopt and setenv's them in the child only; a pair without `=` exits 2."
tags: [run, env, patch-0008, section-14-1, agent-features]
created: "2026-11-22T16:24:25.913Z"
updated: "2026-11-22T16:24:25.913Z"
---
`busybox run --env NAME=VALUE` sets environment variables for the child only, and is repeatable. Parent environment is never inherited wholesale from `--env`, so a run's environment is deterministic. AGENT-FEATURES §14.1; ships in `patches/0008-agent-ops-run.patch`.

```text
  run --env A=1 --env B=two -- sh -c 'echo $A-$B'
        ├─ pairs peeled off argv before getopt32long  (so -T/-D/-F keep working)
        ├─ parent env untouched
        └─ child: setenv(name, value, 1) before exec
```

```
$ run --env A=1 --env B=two -- sh -c 'echo "$A-$B"'
1-two

$ run --env B=inner -- sh -c 'echo "B=$B"'      B=inner
$ run -- sh -c 'echo "B=${B:-unset}"'           B=unset        # nothing leaked
$ run --env NOEQ -- true                        run: --env needs NAME=VALUE   # exit 2
```

## Implementation notes

- `--env` is parsed by a **pre-scan** that removes `--env NAME=VALUE` (and `-e NAME=VALUE`) pairs from `argv` before `getopt32long`, because the option repeats and busybox's `getopt32long` only keeps the last occurrence. The same technique carries `log --diff R1:R2`.
- The child applies each pair with `setenv(name, value, 1)` immediately before `exec`/`execvp`, so a variable can be overridden in place (existing convention: last one wins) but never reaches the parent.
- A pair without `=` is a usage error: message on stderr, exit **2** (the applet's usage-error code), no run created.

Suite after the change: 1299 passed on darwin-arm64; `busybox patchcheck` -> checked=14 bad=0.
