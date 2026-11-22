---
title: "AGENT-FEATURES §14: further developments, and why the test runner must be called `check`"
kind: "architecture"
summary: "AGENT-FEATURES.md §14 proposes per-applet extensions, six new applets (json, patchcheck, snapshot, bench, why, check), NDJSON + schema deprecation conventions, and a six-point acceptance gate; patches continue at 0009."
tags: [agent-features, roadmap, section-14, naming, acceptance]
created: "2026-11-22T13:36:36.876Z"
updated: "2026-11-22T13:36:36.876Z"
---
`AGENT-FEATURES.md` now carries a forward-looking §14 alongside the shipped §1-§12 and the dogfooding §13: per-applet extensions, six new applet proposals, three cross-cutting conventions, and a six-point acceptance checklist. Patch numbering continues at `0009`.

```text
  shipped 0006-0008            §14.1 extend              §14.2 new          gate
  peek replace run log         peek: multi-range,        json               §2 contract
  waitfor doctor --caps        --follow, --diff          patchcheck         §6 portability
                               replace: multi-edit,      snapshot           §7 size 5%
  §13 dogfooding priorities -> --backup                 bench              test on Darwin
  test --format json           run: --pgid/--env/--pty   why                + AlmaLinux
  --caps build object          log: --diff               check  <-- not `test`
```

## 14.2 applet names and the one trap

`json`, `patchcheck`, `snapshot`, `bench`, `why`, and **`check`**. The structured test runner must not be called `test`: `test`, `[` and `[[` are already applets, so an applet named `test` is unreachable from a script — the same shadowing that ruled out `wait` in §4.3.

## 14.3 conventions to settle first

NDJSON for unbounded output (`snapshot`, `check`) so `run`/`log --match` can select without a parser; `schema:1` frozen with a one-release deprecation window; every error code named in §2 and repeated in `--caps`; and `run --env` must not inherit the whole environment.

## 14.5 acceptance gate

Exit codes from §2 only (usage 2, nothing above 125); `{"schema":1}` JSON with text still the default; every output bounded with `truncated` plus a continuation; no per-platform behaviour; a check green on Darwin *and* in an AlmaLinux container; size measured against the 5% budget.

Each item traces to friction observed while using the shipped set: unselectable checks and `grep -c` on JSON (→ `check`, `json`), manual `git apply --check -R` (→ `patchcheck`), stray `inetd`/`fakeidentd` daemons (→ `run --pgid`, `prune`), and "did my change alter behaviour?" answered by copying logs (→ `log --diff`, `snapshot`).
