---
title: "Dogfooding priorities: read-only applets before any sandbox, cleanup before unattended runs"
kind: "decision"
summary: "Nine dogfooding tools ranked in AGENT-FEATURES.md §13; ship the read-only five first (test --format json, json, patchcheck, --caps build object, why), and gate adversarial.sh behind run-scoped cleanup."
tags: [dogfooding, harness, test-runner, json, patchcheck, agent-tooling]
created: "2026-11-22T13:34:58.486Z"
updated: "2026-11-22T13:34:58.486Z"
---
The remaining friction in this project is in the harness layer, not the binaries: 1,741 lines of bash (`test.sh` 366, `stress.sh` 551, `adversarial.sh` 507, `tests/agent-ops.sh` 317) still do work that a few read-only applets could do, and every one of the nine recommendations in `AGENT-FEATURES.md` §13 came from a concrete failure while using the suite on this repo.

```text
  harness layer (bash)                applet surface that would replace it
  ck name expected actual      ->     test --format json {name,status,actual,ms}
  grep -c '"status":"ok"'      ->     json get / json validate
  git apply --check -R (manual)->     patchcheck patches/*.patch
  build-all.sh table           ->     busybox --caps --format json (build object)
  grep .config + prune list    ->     why APPLET  (CONFIG symbol + file:line)
  ps | grep | kill -9 strays   ->     run --pgid, reap R<n>
  copying logs to compare      ->     log --diff R3 R4
  time ./test.sh               ->     bench -n5 -- CMD
  "no such file: llvm-ar"      ->     doctor --build
```

## Priority

Ship the read-only five first (`test --format json`, `json`, `patchcheck`, `--caps` build object, `why`): none of them can make a release worse, and each removes a `sed`/`grep` one-liner from the harness.

`reap`/`--pgid` is the one with a safety edge: `adversarial.sh`'s `SKIP_MATRIX` omits `reboot`/`poweroff`/`halt`/`init`, all enabled in the Linux build, so it must not run unattended as root until a run-scoped cleanup contract exists. Six stray `inetd`/`fakeidentd` daemons from that suite had to be killed by hand during this session.

## Not worth building

Cgroup/namespace sandboxing (Linux-only, breaks the cross-platform contract in §6), file watching (`inotify`/`kqueue` shim), CI orchestration, MCP, a full `jq` clone.
