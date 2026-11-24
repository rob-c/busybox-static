---
title: "The contract now separates shipped shapes from proposals"
kind: "architecture"
summary: "`BUSYBOX-CONTRACT.md` marks the four fixed defects and the withdrawn `--match` claim, documents `-n`, and puts nine proposals under a \"not in this build\" heading with the measurement behind each."
tags: [contract, documentation, proposal, timeline, pi-managed-tools]
created: "2026-11-23T16:50:11.692Z"
updated: "2026-11-23T16:50:11.692Z"
---
`BUSYBOX-CONTRACT.md` now separates what ships from what is proposed: sections 1–8 describe the current build (including the four defects that are fixed and one claim that is withdrawn), section 9 lists nine proposals under a heading that says **not in this build**, and section 10 names the suites that pin the contract.

```text
  §1-2  identity + peek          unchanged shapes
  §3    replace                  unchanged
  §4    run/log                  + -n/--stamp-ns, text timeline head+tail
  §4    defects reported by the plugin
          unzip -d DIR             Fixed in 0.5.1  (BSD vs glibc getopt)
          --prune under -t         Fixed in 0.5.1  (rmdir failed on timeline file)
          text timeline head-only  Fixed in 0.5.1  (3/4 head, 1/4 tail, marker)
          -B 0 "no limit" hint     Fixed in 0.5.1  (hint now says zero budget)
          --match on timeline      WITHDRAWN      (it works; default context 3)
  §9    proposed, not implemented  9 items, value/risk ordered
  §10   verification recipe        tests/plugin-reports.sh R1-R5, agent-ops, streams
```

## Why a "not in this build" section

The contract is read by a plugin that codes against it. A proposal written in the same voice as a shipped flag becomes a defect report the day someone trusts it — which is exactly how `--prune` and `unzip -d` were found. So section 9 opens with *nothing below exists yet, do not code against it*, and each item carries the measurement that motivates it:

| proposal | measured gap it closes |
|---|---|
| `log --since/--until`, `--around-gap`, `--summary`, `events[]` | the plugin parses `[   0.011354 out] …` in TypeScript (`timing.ts`) because the timeline comes back as strings |
| `run --idle-timeout` | the plugin now applies a **120 s default deadline**, so a slow-but-working build dies like a hang |
| `mark` applet + `BUSYBOX_RUN_ID` | phases are inferred from prose; no child-side clock |
| `log --sample N` | `brief` cannot reduce 40 000 distinct lines |
| `run --jsonl` | JSON appears only at exit |
| `patchapply` | `replace` takes one literal; models emit diffs |
| `outline` | `peek` is line- and byte-addressed only |
| `log --diff-timeline` | "slower than before" needs a second full read |
| `--caps .features` | lists `brief`/`pty`/`timeline`? no — a client cannot feature-detect them |

## Keeping the mirror honest

This repository's copy is a mirror of the plugin's. Updating it here without the same edit there guarantees divergence, so the rule is: change the file in whichever repository noticed the drift, then re-sync the other *in the same change set*, and re-run `tests/plugin-reports.sh` — every defect heading in the contract should have a matching section in that suite.
