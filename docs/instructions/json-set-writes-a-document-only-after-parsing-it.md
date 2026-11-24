---
title: "json --set: guarded JSON writing that never half-writes"
kind: "instruction"
summary: "`json --set/--delete` parse first, refuse a missing parent with NOT_FOUND, keep siblings, and replace the file by temp+rename; three silent faults came from option bits, node freeing, and array-path resolution."
tags: [json, set, patch-0004, guarded-write]
created: "2026-11-24T03:01:43.554Z"
updated: "2026-11-24T03:01:43.554Z"
---
`busybox json --set` and `--delete` write a JSON document safely: the whole file is parsed before anything is written, a missing parent answers `NOT_FOUND` and leaves the file byte-identical, the replacement keeps every sibling, and the write is temp+rename with the original mode bits.

```text
  json --set    -f f.json -g .a.b        --value hello      set a string
  json --set    -f f.json -g .a.b        --json-value 42    set any JSON value
  json --set    -f f.json -g '.c[1]'     --json-value 99    replace an array element
  json --set    -f f.json -g .a.added    --json-value '[1]'  append a member
  json --delete -f f.json -g .a.keep                        remove a member
  --dry-run                                                 print, write nothing

  {"a":{"b":1,"keep":true},"c":[10,20,30]}
    --set .a.b hello   →  {"a":{"b":"hello","keep":true},"c":[10,20,30]}
```

## Three faults, and why each was silent

1. **Option bits are the letter's position in the optstring.** `f:g:ktncF:SV:J:DN` makes `S` the 8th → `1 << 7`; the first attempt used `1 << 6`, which is `c` (validate), so `--set` quietly ran as a read.
2. **Replacing a node must keep the node.** Freeing the old member and linking the new one dropped its key (freed with the old node) and its siblings — `{"a":{"b":1}}` came back `{"a":{}}`. The fix swaps only the *payload* (`type`/`str`/`child`) into the existing node.
3. **`.c[1]` must resolve the name before `[`.** The walker parsed the index and returned the document itself as the parent of `1`, so the array element was never found.

The first version passed `--dry-run` and still lost data on write; only comparing the written file — not the command's own report — caught it.

## Tests

`tests/new-applets.sh` section **J2**, 12 checks: dry-run writes nothing, the set lands, a sibling survives, `--json-value` numbers, array index, member append, delete, missing path refused with the file untouched, JSON result shape. Suites: `new-applets` 81, `test.sh` 198, `agent-ops` 1299, `plugin-reports` 26. Patch `0004` regenerated; `patchcheck` → `checked=22 bad=0`.
