# What `pi-managed-tools` requires from the busybox binary

A handoff contract for the **busybox-static** repository: everything below is what
this plugin actually executes and parses, captured from a real build rather than
from the design notes. If a change to the binary breaks one of these, the plugin
breaks silently — most of these fields are read with a default when missing.

- **Build this was verified against:** `1.39.0.git` (2026-11-22 02:59:37 GMT),
  `dist/darwin-universal/bin/busybox`, **269 applets**, `--caps` features
  `gnu-long-opts,peek,replace,waitfor,run,log,doctor,json`.
- **Plugin side:** `src/agentops.ts` (argv building, payload parsing, salvage) and
  the three tools in `src/extension.ts`.
- **Re-capture it yourself:** `./scripts/capture-busybox-contract.sh` in this repo
  prints every invocation below with its real payload.

The plugin **never re-implements a guarantee**: byte budgets, `flock`, atomic
rename, process-group cleanup and 0600 artifacts are all yours. It also never
retries a mutation and never infers success from log text.

---

## 1. Identity checks

| call | what the plugin reads |
|---|---|
| `busybox --list` | applet names, one per line; used to build the symlinked applet directory |
| `busybox --caps --format json` | `.version`, `.count`, `.features[]` — printed by `/managed-tools status` |

`--list` output must stay newline-separated bare names: the plugin intersects it with
its curated list and creates `<agent dir>/busybox-applets/<name>` symlinks. A name
that disappears from `--list` silently loses its bare name on `PATH`.

`--caps` is the only honest source for "which build is installed": the plugin's state
file records the release tag, and a hand-installed build is often ahead of it.

```json
{"schema":1,"version":"1.39.0.git","platform":"darwin","arch":"arm64","count":269,
 "features":["gnu-long-opts","peek","replace","waitfor","run","log","doctor","json"],
 "names":["[","[[","add-shell", "…"]}
```

---

## 2. `peek` — read with a version

Invocations the plugin issues (`src/agentops.ts: peekArgs`, `contentVersion`):

```sh
busybox peek PATH [--lines A:B | --around STR [--context N] [--regex]] \
                  [--from-byte N] [--max-bytes N] --format json
# version probe (one line, one byte, still carries the whole-file hash):
busybox peek PATH --lines 1:1 --max-bytes 1 --format json
```

Payload it parses (single file and `--request` both wrap in `results`):

```json
{"schema":1,"results":[{"path":"f.ts","status":"ok","binary":false,
  "version":"sha256:750d3541c856269c36e78295976696e2f78e5d72d6eb3f6236330392a4555345",
  "lines":[[2,3]],
  "content":[{"n":2,"text":"\tlet total = 0;"}],
  "shown_bytes":57,"truncated":false,"next":null}],"shown_bytes":57}
```

Non-ok and truncated answers it must keep producing:

```json
{"results":[{"path":"nope.ts","status":"error","code":"NOT_FOUND","message":"No such file or directory"}]}
{"results":[{"path":"f.ts","status":"ok","truncated":true,"next":{"from_byte":36},"shown_bytes":40, …}]}
{"results":[{"path":"b.bin","status":"ok","binary":true,"version":"sha256:4163…","content":[],"shown_bytes":0}]}
```

**Fields the plugin depends on:** `results[].status`, `.path`, `.version`, `.lines[]`
pairs, `.content[].n/.text`, `.shown_bytes`, `.truncated`, `.next`, `.binary`,
`.code`, `.message`, and top-level `.unprocessed`.

Two things worth keeping exactly as they are:

- `next` is an **object** `{"from_byte": N}`. It was nearly read as a bare number,
  which silently drops the continuation and forces a re-read. Do not change it to a
  number without saying so.
- `version` is the hash of the **whole file as read**, not of the shown range. The
  plugin hands it back to `replace` as a precondition; if it ever became a
  range-hash, stale-edit detection would silently stop working.
- `--lines`/`--around` remain mutually exclusive (the plugin sends one or the other).

`guessed_type` and a hex `preview` for binary files are **not** in this build's
payload; the formatter tolerates their absence. Adding them is welcome — the plugin
renders `preview` if present and ignores `guessed_type` when absent.

---

## 3. `replace` — guarded edit

Invocations:

```sh
# one edit, the guarded form (hash checked under the lock):
busybox replace PATH --old STR --new STR [--expect N] [--sha256 HEX] \
                     [--dry-run] [--follow] [--max-diff-bytes N] --format json
# several edits: the only form that validates each against the file as it stands
busybox replace --request <0600 temp file> [--dry-run] [--follow] --format json
#   {"edits":[{"path":"…","old":"…","new":"…","expect":1}]}
```

A single-file answer is **flat**, a `--request` answer wraps in `results` — both
shapes must stay:

```json
{"schema":1,"path":"r1.ts","status":"ok","dry_run":false,"changes":1,
 "old_version":"sha256:750d…","new_version":"sha256:824a…","changed":true,
 "diff":"@@ -4,1 +4,1 @@\n \t\n-return total + 1;\n+return total;\n","diff_truncated":false}
```

```json
{"schema":1,"path":"r3.ts","status":"error","code":"STALE_INPUT","message":"content version is sha256:750d…"}
{"schema":1,"path":"r4.ts","status":"error","code":"AMBIGUOUS_MATCH","message":"expected 1 occurrence(s), found 3; candidate lines: 2,3,4","candidates":[2,3,4]}
{"schema":1,"results":[{"path":"r6.ts","status":"error","code":"INVALID_ARGUMENT","message":""},{"path":"r6.ts","status":"ok", …}]}
```

**Fields depended on:** `status`, `path`, `code`, `message`, `changes`, `dry_run`,
`changed`, `old_version`, `new_version`, `diff`, `diff_truncated`, and `results[]`
for batch. `candidates[]` is not read (the message carries the lines).

The plugin resolves a **short version prefix** (the 12 characters `peek` prints)
against the current file before handing the full hash to `--sha256`, so the exact
comparison under your lock is preserved. If `--sha256` ever accepted prefixes itself,
that resolution would be redundant but harmless.

---

## 4. `run` / `log` — captured execution

Invocations:

```sh
busybox run [--timeout SECS] [--max-bytes N] [--cwd DIR] [--shell] --format json -- ARGV…
busybox run --pty [--pty-raw] [--pty-split] [--pty-size COLSxROWS] --format json -- ARGV…
busybox log RUN [--lines A:B] [--match STR] [--context N] [--stream stdout|stderr|both] \
                [--meta] [--max-bytes N] --format json
```

`run` payload for a complete view (intact, this is the shape relied on):

```json
{"schema":1,"run":"R12","dir":"/…/busybox-run/R12","exit_code":0,"timed_out":false,
 "cancelled":false,"capture_complete":true,"duration_ms":20,"stdout_bytes":5,
 "stderr_bytes":5,"view_truncated":false,"stdout_view":"out1\n","stderr_view":"err1\n"}
```

`log` payloads:

```json
{"schema":1,"stream":"stdout","status":"ok","lines":[[1,2]],"content":[{"n":1,"text":"FAILED t1"}],"shown_bytes":21,"truncated":false}
{"schema":1,"run":"R17","meta":"cmd=…\ncwd=…\nexit_code=0\n…"}    # --meta is a text blob
{"schema":1,"stream":"stdout","status":"error","code":"NOT_FOUND","message":"no match"}
```

A pty run answers the same payload plus the terminal it built:

```json
{"schema":1,"run":"R13","dir":"/…/busybox-run/R13","pgid":4711,"pty":true,
 "pty_slave":"/dev/pts/3","pty_cols":80,"pty_rows":24,"pty_raw":false,
 "stderr_merged":true,"exit_code":0,…,"stdout_view":"hi\n","stderr_view":""}
```

`pty:false` and no `pty_*` keys are emitted for a pipe run, so a reader that does
not know about ptys is unaffected. With `stderr_merged:true` the guest's stderr
went to its terminal, so `stdout_view` carries both streams in arrival order and
`stderr_view` is empty; `--pty-split` restores two streams with
`stderr_merged:false`. `meta` gains `pty`, `pty_slave`, `pty_rows`, `pty_cols`
and `stderr_merged` lines.

**Fields depended on:** `run`, `dir`, `exit_code`, `timed_out`, `cancelled`,
`capture_complete`, `duration_ms`, `stdout_bytes`, `stderr_bytes`, `view_truncated`,
`stdout_view`, `stderr_view`; for `log`: `stream`, `status`, `code`, `message`,
`lines`, `content[].n/.text`, `shown_bytes`, `truncated`, `meta`; optionally
`pty`, `pty_slave`, `pty_cols`, `pty_rows`, `pty_raw`, `stderr_merged`.

`run`'s exit code is passed through to the tool result but **is not** read as success
or failure: `exit_code: 3` with `timed_out:false` is a child that exited 3. Only
`timed_out`, `cancelled` and an unparseable payload mark a wrapper failure.

### Defect 1 (blocks a clean tool result): `run --format json` is invalid when the view is truncated

`dump_bounded()` prints the head with `json_write_str()`, then the tail with
`json_write_str()` again, producing two adjacent quoted strings at the seam:

```sh
busybox run --max-bytes 120 --format json -- sh -c 'i=0; while [ $i -lt 40 ]; do echo "line $i"; i=$((i+1)); done' | jq .
# jq: parse error: Expected separator between values at line 1, column …
{"schema":1,"run":"R16",…,"view_truncated":true,"stdout_view":"line 0\n…\nlin""e 34\n…","stderr_view":""}
```

The scalars before the seam are intact and `capture_complete` is true, so the plugin
recovers them (`salvageRunPayload()`), reports `exit_code`/`timed_out`/byte counts,
and points the caller at `busybox log RUN` for the view. It deliberately does **not**
re-run the command to obtain a parseable answer — the command may have side effects.

Expected fix: build one buffer (head + an omission marker + tail), escape it once, and
keep `stdout_view` a single JSON string. A schema-compatible alternative is an array of
strings, but a string is what the current consumers expect.

### Defect 2: a spawn failure is reported as a child exit code

```sh
busybox run --format json -- /nonexistent/prog ; echo $?   # exit_code:127, exit 127
```

`--help` documents exit 1 for "when the command could not be started", and the shared
contract says wrapper failures are distinguishable. At `127` the plugin cannot tell a
missing binary from a child that chose 127, and must not guess from the
`run: can't execute …` text. Suggested: exit 1 plus `"code":"UNSUPPORTED"` (or a new
`SPAWN_FAILED`) in the JSON, keeping `exit_code` for children that actually ran.

---

## 5. `waitfor` / `doctor` — informational

Not wrapped as tools yet; they are linked as bare names and only need their current
shapes stabilised:

```json
{"schema":1,"ready":true,"kind":"file","target":"/tmp/f","attempts":1,"elapsed_ms":0}
{"schema":1,"ready":false,"kind":"file","target":"/tmp/nope","attempts":9,"elapsed_ms":1000,"code":"TIMEOUT"}
{"schema":1,"platform":"darwin","cwd":"/tmp/x","exe":"/…/busybox","shell":"busybox sh","tmp":"/var/folders/…/T/","tmp_writable":true,"deps":{"git":"/usr/bin/git"}}
```

---

## 6. Defect 3: a 0-match `replace` is `INVALID_ARGUMENT` with an empty message

```sh
busybox replace r5.ts --old zzzz --new x --format json ; echo $?
{"schema":1,"path":"r5.ts","status":"error","code":"INVALID_ARGUMENT","message":""}
1
```

The design notes said 0 matches → `NOT_FOUND` with the candidates. Today it is
`INVALID_ARGUMENT` with no message, so the plugin can only show
`"(the build sent no message)"`. Either is workable; a message is not.

Related: in `--request` mode the loop continues past `INVALID_ARGUMENT` and only
breaks on `STALE_INPUT`/`NOT_FOUND`. The plugin's batch summary therefore says
"check each result", not "later edits were skipped".

---

## 7. Compatibility checklist

Safe to change without telling anyone:

- adding applets (the plugin intersects with its own list and reports `--caps` counts);
- adding JSON fields (unknown keys are ignored);
- the text (non-`--format json`) output of anything, since no tool parses it.

**Tell the plugin first** if any of these move:

- a JSON field name the tables above lean on, or `next` losing its object shape;
- `results[]` appearing/disappearing around single-file `replace` answers;
- `--lines`/`--around` no longer being mutually exclusive;
- `version` becoming a range hash instead of a whole-file hash;
- `run`'s wrapper failure no longer being distinguishable from a child's exit status;
- `--list`, `--caps --format json`, or `log --meta` changing shape;
- exit codes leaving the 0/1/2/3 set, or truncation ceasing to be exit 0.

## 8. How this side verifies it

`npm test` (134 tests) covers argv building, payload rendering, the salvage path and
cancellation against a stand-in binary; `tests/agentops.test.ts` asserts the shapes in
this document, including the broken `run` payload as a fixture. The end-to-end check
is a real pi session running: `busybox_peek` → `busybox_replace` with the returned
version → `busybox_run` of a failing command → `busybox_run run_id=… match=…` → the
same `busybox_replace` again, which must answer `STALE_INPUT` and change nothing.
