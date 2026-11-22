---
title: "`peek -p` emits `preview` in JSON mode (patch 0006)"
kind: "instruction"
summary: "`peek -p --format json` emits `preview` (hex view, 64 bytes) and `guessed_type`; before, `-p` was a no-op in JSON and the plugin rendered an empty body for binary files."
tags: [peek, preview, binary, patch-0006, busybox-contract]
created: "2026-11-22T17:32:24.679Z"
updated: "2026-11-22T17:32:24.679Z"
---
`busybox peek -p --format json` now carries `"guessed_type":"binary"` and a `"preview"` string holding the same hex view text mode prints, of at most 64 bytes. Without `-p` the two keys are absent, so existing parsers see no change. Ships in `patches/0006-agent-ops-core.patch`.

```text
  peek -p bin2.dat --format json
    {"path":"bin2.dat","status":"ok","binary":true,"version":"sha256:…",
     "guessed_type":"binary",
     "preview":"000000  00 01 41 42 ff fe                                ..AB..\n",
     "lines":[[1,1]],"content":[],"shown_bytes":0,"truncated":false,"next":null}
```

## Why it was missing

`-p`/`--preview` only reached `hex_preview()`, which writes straight to stdout, and the JSON branch called it only when `!o->json`. So the documented flag did nothing in the mode tools use. `hex_preview_text()` renders the identical layout into a buffer (`%06x` offset, 16 hex pairs, ASCII gutter) and the JSON writer escapes it once.

## Contract note

BUSYBOX-CONTRACT.md §2: "`guessed_type` and a hex `preview` for binary files are not in this build's payload; the formatter tolerates their absence. Adding them is welcome — the plugin renders `preview` if present and ignores `guessed_type` when absent." Both are additive keys, which §7 lists as safe.

## What the plugin does with it

`src/agentops.ts` prints `binary=true guessed_type=<…>` in the header and uses `preview` as the body instead of `numbered(result.content)` — previously that body was empty for every binary file, so an agent saw only "binary=true" and a hash.

Suite: 1299 passed on darwin-arm64; `busybox patchcheck` -> checked=14 bad=0.
