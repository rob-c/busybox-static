---
title: "`why` applet: built but reports \"unknown\" — and the rest of the §13/§14 tranche is unstarted"
kind: "instruction"
summary: "`why` (patch 0009) builds but returns \"unknown\" for every applet despite CONFIG_PEEK=y in .config; the rest of the §13/§14 tranche is not started."
tags: [why, patch-0009, unverified, section-14, roadmap]
created: "2026-11-22T13:41:33.203Z"
updated: "2026-11-22T13:41:33.203Z"
---
`why` (patch 0009, `src/miscutils/why.c`) is the first item of the §13/§14 tranche. It compiles and runs, but it reports every applet as `unknown` even when `.config` contains `CONFIG_PEEK=y` (build/darwin-arm64/.config:312), so `config_state()` is not finding the line it looks for. It is unverified and must not be described as working.

```text
  busybox why peek        ->  "unknown peek"
  build/darwin-arm64/.config:312  ->  CONFIG_PEEK=y
  busybox --caps          ->  features=[... "peek" ...]   (applet IS present)

  so: the explainer is wrong, not the build
```

## State

- Builds clean on darwin-arm64 after replacing `bb_toupper` (not a libbb export) with an ASCII compare.
- `busybox why peek --format json` emits `{"applet":"peek","symbol":"PEEK","state":"unknown",...}` while the same directory's `.config` line 312 reads `CONFIG_PEEK=y`.

## Likely cause, for the next pass

`config_state()` opens `.config` relative to the current directory and silently returns NULL on failure, which the caller renders as "unknown" rather than "could not read". Check that the open succeeded before blaming the parse, and make a missing config an explicit error.

## The rest of §13/§14

Not started: `json`, `patchcheck`, `snapshot`, `bench`, `check`, the `--caps` build object, `doctor --build`, and the per-applet extensions. Patch numbers from `0009` upward.
