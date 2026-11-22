---
title: "`peek --follow SECS` is a bounded tail -f (patch 0006)"
kind: "instruction"
summary: "`busybox peek --follow SECS --from-byte N FILE` emits bytes appended during the window (50 ms fstat poll, capped by --max-bytes) then a summary line; it runs before the request envelope."
tags: [peek, follow, tail-f, patch-0006, section-14-1]
created: "2026-11-22T16:35:18.681Z"
updated: "2026-11-22T16:35:18.681Z"
---
`busybox peek --follow SECS` emits the bytes appended to a file during a bounded window, starting at `--from-byte` — a `tail -f` that cannot run forever and needs no inotify or kqueue, so Darwin and Linux behave identically. AGENT-FEATURES §14.1; ships in `patches/0006-agent-ops-core.patch`.

```text
  printf 'one\n' > log.txt
  peek --follow 1 --from-byte 4 log.txt      (another writer appends 'two\n')
        ├─ lseek to from_byte, read to EOF
        ├─ poll fstat/file offset every 50 ms until SECS elapse or budget is full
        └─ print the appended bytes, then followed=<n> from_byte to_byte truncated
```

```
$ peek --follow 1 --from-byte 4 log.txt
two
followed=4 from_byte=4 to_byte=8 truncated=false      # exit 0

$ peek --follow 0 --format json log.txt
{"schema":1,"path":"log.txt","from_byte":0,"to_byte":8,"emitted":8,"truncated":false}
```

## Design notes

- The loop is `read()` to EOF, then sleep 50 ms and re-read; the deadline is a countdown of milliseconds, so the applet cannot hang if the writer never writes. `--max-bytes` still caps the emitted bytes and sets `truncated`.
- Output is the raw appended bytes followed by a one-line (or one-object) summary — the summary is what a script should parse, the bytes are what a human reads.
- Handled in `peek_main` **before** the request envelope, like `--diff`: emitting from inside the per-request path produces a second `{"schema":1,…}` and unparseable JSON.
- `json_member_str("path", …)` already writes the `"path":` key; prefixing `,"path":` produces `"path":"path":"log.txt"`.

Suite after the change: 1299 passed on darwin-arm64; `busybox patchcheck` -> checked=14 bad=0.
