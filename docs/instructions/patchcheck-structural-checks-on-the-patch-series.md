---
title: "`patchcheck`: structural checks on the patch series (patch 0011)"
kind: "instruction"
summary: "`busybox patchcheck [-d DIR] [--format json]` flags numbering gaps, missing ---/+++/@@ headers, CR bytes and empty patches without git; sort by name first or every patch reports a false gap."
tags: [patchcheck, applet, patch-0011, patches, agent-features]
created: "2026-11-22T14:31:47.359Z"
updated: "2026-11-22T14:31:47.359Z"
---
`busybox patchcheck` validates the `patches/` series without git: numbering gaps, missing `--- `/`+++ `/`@@` headers, CR bytes and empty files. Ships as `patches/0011-agent-ops-patchcheck.patch`; run it after regenerating any tier patch, before the slower `git apply --check -R`.

```text
  regenerate patch  →  busybox patchcheck          cheap: headers, gaps, CR, empty
                    →  git apply --check -R …      real: does it reverse-apply
```

```
$ busybox patchcheck
ok   0001-fix-aarch64-build-rpm-pagesize.patch
…
checked=11 bad=0

$ busybox patchcheck --format json
{"schema":1,"status":"ok","dir":"patches","count":11,"bad":0,"patches":[{"name":"…","ok":true},…]}
```

## Two traps hit while writing it

- **Diff headers are three dashes, not two.** `--- /dev/null` is `-`,`-`,`-`,` `; matching `p[2]==' '` misses every patch, so a brand-new-file patch reports "no '--- ' header" while a modified-file one passes. Test `p[0..2]` equal the char and `p[3]==' '`.
- **`readdir()` order is arbitrary**, so the contiguity check must sort by name first. Unsorted, the first run reported `numbering gap: expected 0001` on all ten patches — a false alarm that looks exactly like a real one.
- Entry point must be `patchcheck_main_main` (applet name is already `patchcheck`), and `CONFIG_PATCHCHECK=y` goes in **both** `EXTRA_CONFIG` blocks in `build.sh`.

Structural only — it does not apply the patch, so `git apply --check -R` remains the real verification.
