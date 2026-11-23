# What `pi-managed-tools` requires from the busybox binary

A handoff contract for the **busybox-static** repository: everything below is what
this plugin actually executes and parses, captured from a real build rather than
from the design notes. If a change to the binary breaks one of these, the plugin
breaks silently — most of these fields are read with a default when missing.

- **Build this was verified against:** the **0.5.1** tree, busybox
  `1.39.0.git`, asset `busybox-static-1.39.0-aac079e-darwin-universal`, **276 applets**,
  `--caps` features `gnu-long-opts,peek,replace,waitfor,run,log,doctor,json`.
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
| the release's asset list (`GET /repos/rob-c/busybox-static/releases/tags/v0.4.0`) | the asset to download, matched by `^busybox-static-[\d.]+(-[0-9a-f]+)?-<target>$` — the project version is in the tag, the *busybox* version is in the asset name |
| `busybox --caps --format json` | `.version`, `.count`, `.features[]` — printed by `/managed-tools status` |

`--list` output must stay newline-separated bare names: the plugin intersects it with
its curated list and creates `<agent dir>/busybox-applets/<name>` symlinks. A name
that disappears from `--list` silently loses its bare name on `PATH`.

`--caps` is the only honest source for "which build is installed": the plugin's state
file records the release tag, and a hand-installed build is often ahead of it.

**Keep the asset naming as it is and say so if it changes.** Since 0.4.0 the tag is the
project version (`v0.4.0`) while the assets carry the busybox version
(`busybox-static-1.39.0-aac079e-darwin-universal`). The plugin therefore matches the
asset by pattern instead of constructing it from the tag, and treats a recorded
`1.39.0-aac079e` (the old scheme, which sorts *above* 0.4.0) as older than any release.
The `-pure` asset must stay distinguishable by name: it drops `nslookup`, which the
curated applet set uses, so the pattern deliberately does not match `…-universal-pure`.

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
busybox run [--timeout SECS|-T] [--kill-after SECS|-k] [--max-bytes N|-B] \
            [--timestamps|-t] [--stamp-ns|-n] \
            [--capture-limit N|-C] [--dir PATH|-D] [--cwd DIR|-d] [--shell|-s] \
            [--stdin FILE|-i] [--pgid|-P] [--env NAME=VALUE|-e] [--prune N|-r] \
            [--quiet|-q] [--timestamps|-t] [--brief-json|-j] \
            [--brief stdout|stderr|both|-b] [--error-ids|-I] [--format text|json|-F] \
            -- ARGV…
# the timeline, which the plugin turns on for every bash call:
busybox run --timestamps --max-bytes 48000 --env PYTHONUNBUFFERED=1 -- /bin/bash -c '…'
busybox log RUN [--lines A:B] [--match STR] [--context N] \
                [--stream stdout|stderr|timeline|both] [--meta] [--diff R1:R2] \
                [-B N] --format json
```

`-Y/--pty`, `--pty-raw`, `--pty-split` and `--pty-size COLSxROWS` give the child a
pseudo-terminal. The plugin uses **`--pty-split`** for every bash call: stdout on the pty
(so libc line-buffers and the offsets are real), stderr on its own pipe (unbuffered
anyway, and it keeps the `err` tag). Measured with a C program that `printf`s three lines
1.2 s apart, built `-O0` without an `fflush`: on a pipe every line carried `3.740564`; on
the pty the lines carried `0.004561 / 1.209525 / 2.414571`. Python and Ruby have their own
switches (the wrapper sets those too); C stdio, Java and Go's `bufio` have only the
terminal. `isatty()` is true for the child in pty mode — the
environment is otherwise untouched, and `--pty-split` keeps the streams apart. stdin is
fed through the master and terminated with `VEOF`, so a prompt sees EOF instead of
hanging. `--format json` reports `"pty":true`, and the timeline is unchanged.

`-t/--timestamps` prints one interleaved line per record, `[   0.011354 out] text`.
`-n/--stamp-ns` widens that stamp to nine digits and declares the clock's own granularity
(`stamp=ns res_ns=41` on Apple Silicon and on ARM Linux; the Darwin build needs
`CLOCK_MONOTONIC_RAW`, because `CLOCK_MONOTONIC` is quantised to 1 µs there). **`-n` is
accepted but missing from `run --help`** — a known gap, not a hidden feature to rely on
silently.
`--quiet` drops the summary but is ignored when `-t` is set; `--brief WHICH` reduces a
stream through `brief -d` and is *also* ignored when `-t` is set (the timeline branch is
taken first). The plugin therefore uses `-t` for the timeline modes and `--brief` only
for its `brief` verbosity, which has no timeline. `brief` is reachable on its own too
(`busybox brief -d -t 5`), and prints a `[brief] lines_in=… records=… merged=…` marker
line of its own.

`run` payload for a complete view (intact, this is the shape relied on):

```json
{"schema":1,"run":"R12","cmd":"sh -c echo out1","dir":"/…/busybox-run/R12","pgid":55107,
 "exit_code":0,"timed_out":false,"cancelled":false,"capture_complete":true,"duration_ms":20,
 "stdout_bytes":5,"stderr_bytes":5,"view_truncated":false,
 "stdout_view":"out1\n","stderr_view":"err1\n"}
```

With `-t` the payload gains the timing the plugin cares about (microseconds from
process start, one entry per line, both streams in arrival order):

```json
{"schema":1,"run":"R111","started_unix_us":1795375794796448,
 "timeline":[{"us":6926,"stream":"out","text":"x"},{"us":6952,"stream":"err","text":"y"}],
 "timeline_lines":2,"timeline_shown":2,"timeline_truncated":false, …}
```

`log --stream timeline` replays that view from the run directory (it needs a run created
with `-t`: without it the artifact does not exist and the answer is
`{"status":"error","code":"NOT_FOUND","message":"run not found or stream missing"}`).
`--match`, `--lines` and `--context` all apply to it; the default context is 3, so
`--match STR` alone also returns the neighbouring lines — use `--context 0` when only the
hit is wanted. An earlier draft of this document reported `--match` as ignored on the
timeline stream; that was a misreading of exactly this default, and the claim is withdrawn.
`--stream both --format json` returns two objects. A truncated `stdout_view` is a single
JSON string with an in-band marker — `… line 5\n... [310 bytes] ...\ne 34 …` — which is
valid JSON since 0.4.0.

`log` payloads:

```json
{"schema":1,"stream":"stdout","status":"ok","lines":[[1,2]],"content":[{"n":1,"text":"FAILED t1"}],"shown_bytes":21,"truncated":false}
{"schema":1,"run":"R17","meta":"cmd=…\ncwd=…\nexit_code=0\n…"}    # --meta is a text blob
{"schema":1,"stream":"stdout","status":"error","code":"NOT_FOUND","message":"no match"}
```

**Fields depended on:** `run`, `dir`, `exit_code`, `timed_out`, `cancelled`,
`capture_complete`, `duration_ms`, `stdout_bytes`, `stderr_bytes`, `view_truncated`,
`stdout_view`, `stderr_view`; for `log`: `stream`, `status`, `code`, `message`,
`lines`, `content[].n/.text`, `shown_bytes`, `truncated`, `meta`.

`run`'s exit code is passed through to the tool result but **is not** read as success
or failure: `exit_code: 3` with `timed_out:false` is a child that exited 3. Only
`timed_out`, `cancelled` and an unparseable payload mark a wrapper failure.

### Fixed in 0.4.0: `run --format json` was invalid when the view was truncated

`dump_bounded()` prints the head with `json_write_str()`, then the tail with
`json_write_str()` again, producing two adjacent quoted strings at the seam:

```sh
busybox run --max-bytes 120 --format json -- sh -c 'i=0; while [ $i -lt 40 ]; do echo "line $i"; i=$((i+1)); done' | jq .
# jq: parse error: Expected separator between values at line 1, column …
{"schema":1,"run":"R16",…,"view_truncated":true,"stdout_view":"line 0\n…\nlin""e 34\n…","stderr_view":""}
```

0.4.0 emits a single string with an omission marker (`... [310 bytes] ...`), which
parses. `salvageRunPayload()` in `src/agentops.ts` is kept as the fallback for older
builds: it recovers the scalars from the text and points at `busybox log RUN`, and
deliberately never re-runs the command (the command may have side effects).

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

### Closed in 0.5.0: an external signal used to leak the child

```sh
busybox run --timestamps -- sleep 30 & pid=$!
kill -TERM $pid ; wait $pid        # exit=143, and `sleep 30` is still running
pgrep -fl "sleep 30"               # 68292 sleep 30
```

0.5.0 fixes the two causes named here. `run` installed its handler on SIGHUP/SIGALRM
(`bb_signals()` takes `1 << signo`, and `run` passed `1 << (signo - 1)`), so a SIGTERM
killed it outright; and a watchdog in its own process group now kills the command's group
when the wrapper disappears for any reason, SIGKILL included. Both verified on 0.5.0:

```sh
run -- sh -c 'sleep 31337' & kill -TERM $!   # exit 3, cancelled=true, no survivor
run -- sh -c 'sleep 31337' & kill -9   $!    # no survivor after the watchdog fires
```

What the plugin still does, now as belt-and-braces rather than necessity:

- takes pi's per-call deadline over one second earlier (`--timeout N-1`), so the applet
  owns the deadline and the timeline is still printed when it expires;
- for its own tools, `runApplet()` stops waiting three seconds after its TERM and resolves
  the tool call regardless, so a wedged wrapper cannot hold a tool open.

Also fixed in 0.5.0: two concurrent runs in one artifact root could pick the same run id
and truncate each other's artifacts. pi issues bash calls in parallel, so this mattered.

### Fixed in 0.5.1: `unzip -d DIR` extracted nothing and exited 0

```sh
busybox unzip -q pkg.zip -d out ; echo $?    # 0, and `out` is empty
busybox unzip -q pkg.zip                     # extracts into cwd, correctly
```

**Fixed in 0.5.1.** BSD getopt stops at the first non-option while glibc permutes, so
`-d out` after the archive was read as member names on macOS only. `-d DIR`, `-dDIR` and
`-qd DIR` are now peeled out of argv wherever they appear:

```sh
unzip -q pkg.zip -d out && ls out    # 1 file        (0.5.1)
unzip -q -d out pkg.zip              # same
unzip -q pkg.zip -dout               # attached form
```

Pinned by `tests/plugin-reports.sh` section R2.

Same archive, same binary: with `-d` nothing is written, without it the files appear. This
is the applet the plugin links as a bare `unzip`, and the one its own zip installer used to
resolve — which silently broke every zip-based install (ast-grep, ninja, gh) once the applet
directory was on PATH. The plugin now resolves a system unzip/bsdtar first, so it is only a
model-facing annoyance, but a model that runs `unzip -d out pkg.zip` gets an empty directory
and a success code.

### Fixed in 0.5.1: `--prune N` was ignored whenever `--timestamps` was set

```sh
for i in $(seq 30); do run -q --prune 5 -- true ; done   # 5 directories left
for i in $(seq 30); do run -t --prune 5 -- true ; done   # 30 directories left
```

**Fixed in 0.5.1.** `prune_runs()` unlinked a fixed list (`stdout`, `stderr`, `meta`) and then
`rmdir` failed on the extra `timeline` file; it now empties the directory entry by entry.
Measured: eight runs with `-t -q --prune 3` leave three directories. Pinned by
`tests/plugin-reports.sh` section R1.

The wrapper always asks for the timeline, so its `--prune` never took effect and a session
left hundreds of run directories behind. The plugin sweeps the root itself now (newest 20,
`R<number>` directories only, symlinks untouched). Worth fixing in `run`: the option should
either work in both branches or say it does not apply.

### Fixed in 0.5.1: the text timeline kept only the head

`run -t` prints `timeline_lines=N shown=M truncated=true` and then the first M lines — no
tail, unlike the JSON `stdout_view`, which keeps head and tail around an omission marker.
For a failing test suite the interesting part is the end, so the plugin's digest names
`busybox log RUN --lines <N-40>:<N>`. **Fixed in 0.5.1.** The text view now spends three quarters of `--max-bytes` on the head and
one quarter on the tail, with one marker between them, and reports `shown=` as head+tail:

```text
[00000.011425 out] line 11
... [timeline truncated: 16 of 40 lines shown (24 omitted); `log R1 --stream timeline' has them] ...
[00000.011642 out] line 36
```

The phrase `timeline truncated: N of M lines shown` is kept on purpose — existing greps and
the plugin's digest look for it. Pinned by `tests/plugin-reports.sh` section R4.

### Fixed in 0.5.1: the `-B 0` hint claimed "no limit"

```sh
brief -B 0 pytest.log            # marker only: shown_lines=0 bytes=0 truncated=1 truncated_by=budget
brief -B 40000 pytest.log        # the whole body (33719 bytes) — a big number is how you say "all"
brief -d -B 400 -F json …        # hints: ["the byte budget stopped the view: raise -B, or -B 0 for no limit"]
```

**Fixed in 0.5.1.** `-B 0` stays a zero budget (consistent with `peek`/`run`) and the hint now
reads `the byte budget stopped the view: raise -B (-B 0 is a zero budget)`. Pinned by
`tests/plugin-reports.sh` section R3. Either
the flag should treat 0 as unlimited (matching the hint) or the hint should stop saying so.
The plugin's skills document the real behaviour, since the hint is the thing a model reads.

### Behaviour worth stating: `-R` matches literal text, not a regex

```sh
brief -R '^FAILED' pytest.log    # matched=1, shown_lines=0 — the caret is part of the string
brief -R FAILED pytest.log       # the failure record through the next match, as intended
```

`-R STR` is documented as "containing STR", which is accurate, but an anchored pattern is
the natural thing to write and it yields `matched=1, shown_lines=0, truncated_by=record_size`
— a match reported, nothing shown. The skills say "literal,
not a regex" and a test forbids an anchored `-R` in an example.

### Behaviour worth stating: split streams can tie

With `--pty-split` a stdout line and a stderr line written in the same instant can be
ordered either way by a few hundred microseconds, because they travel via different kernel
paths. The timestamps show the tie (`0.226112` vs `0.226200`); only `--pty` (merged) gives a
single-kernel-path order. Do not promise a strict cross-stream order for concurrent writes.

## 5. `waitfor` / `doctor` — informational

Not wrapped as tools yet; they are linked as bare names and only need their current
shapes stabilised:

```json
{"schema":1,"ready":true,"kind":"file","target":"/tmp/f","attempts":1,"elapsed_ms":0}
{"schema":1,"ready":false,"kind":"file","target":"/tmp/nope","attempts":9,"elapsed_ms":1000,"code":"TIMEOUT"}
{"schema":1,"platform":"darwin","cwd":"/tmp/x","exe":"/…/busybox","shell":"busybox sh","tmp":"/var/folders/…/T/","tmp_writable":true,"deps":{"git":"/usr/bin/git"}}
```

---

## 6. Fixed in 0.4.0: a 0-match `replace` reported `INVALID_ARGUMENT` with no message

```sh
busybox replace r5.ts --old zzzz --new x --format json ; echo $?
{"schema":1,"path":"r5.ts","status":"error","code":"INVALID_ARGUMENT","message":""}
1
```

0.4.0 answers `NOT_FOUND` with `"expected 1 occurrence(s), found none"`, and
`--sha256` now accepts the 12-character prefix `peek` prints (the plugin still resolves
a prefix itself, which is harmless and keeps 0.3.x usable). `peek -p --format json` also
emits `preview` (hex) and `guessed_type`, which the peek formatter already renders.

Related: in `--request` mode the loop continues past `INVALID_ARGUMENT` and only
breaks on `STALE_INPUT`/`NOT_FOUND`. The plugin's batch summary therefore says
"check each result", not "later edits were skipped".

---

## 6b. `run --help` does not list the options that exist

0.5.0 added `-Y`, `--pty-raw`, `--pty-split` and `--pty-size` to `run --help`, but
`-t/--timestamps`, `-q/--quiet`, `-j/--brief-json` and `-I/--error-ids` are still missing
from it while being accepted by `getopt32long`, and `log --help` still describes `--stream`
without `timeline`. The plugin documents these itself, but a binary should not hide its own
features.

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
- `--timestamps`/`--brief` precedence changing (today the timeline wins and `--brief` is
  ignored), or the timeline prefix format `[   0.012345 out] ` changing — the bash
  renderer strips exactly that shape for the human;
- `--pty-split` semantics changing (stdout a terminal, stderr a pipe, environment
  untouched): the wrapper's honest timing depends on stdout being a tty, and every
  command's `isatty()` answer depends on `--pty-split` staying the split one;
- the `"pty"` field, the watchdog's behaviour on SIGKILL, or `run`'s exit 3 on a signal;
- `--list`, `--caps --format json`, or `log --meta` changing shape;
- exit codes leaving the 0/1/2/3 set, or truncation ceasing to be exit 0.

## 8. How this side verifies it

`npm test` (134 tests) covers argv building, payload rendering, the salvage path and
cancellation against a stand-in binary; `tests/agentops.test.ts` asserts the shapes in
this document, including the broken `run` payload as a fixture. The end-to-end check
is a real pi session running: `busybox_peek` → `busybox_replace` with the returned
version → `busybox_run` of a failing command → `busybox_run run_id=… match=…` → the
same `busybox_replace` again, which must answer `STALE_INPUT` and change nothing.

---

## 9. Proposed additions — **not in this build**

Nothing below exists yet. Do not code against it; each item names the measurement that
motivated it and the shape it would take, so the plugin side can say "yes/not yet" before
anyone writes C. Ordering is by value per unit of risk.

### 9.1 Time-addressed retrieval (highest value)

The timeline is captured well and read badly: the plugin re-parses `[   0.011354 out] …`
with a regex because `log --stream timeline --format json` returns `content[].text`
strings. The question after a summary is *what happened between 6.1 s and 8.4 s*.

```sh
log RUN --stream timeline --since 6.1 --until 8.4 --format json
log RUN --stream timeline --around-gap 0.5 --limit 3 --format json   # the 3 longest silences
log RUN --summary --format json      # total, lines, first out/err, longest gap, errors, exit
```

Adds `events:[{n,us,stream,text}]` beside `content[]` (additive), `gaps:[{from_us,to_us,lines}]`,
and a `summary` object. Removes `timing.ts`'s parser and `summarizeTiming` from the plugin.

### 9.2 A deadline that distinguishes "stuck" from "slow"

The plugin now applies a **120 s default deadline** to every wrapped bash call, so a long
build that is working fine dies like a hang. `--idle-timeout` separates them:

```sh
run --timeout 600 --idle-timeout 60 -- make -j8
# no output for 60 s -> code:"IDLE_TIMEOUT", exit 3, partial capture kept
```

### 9.3 Instrumented guests

```sh
run --env BUSYBOX_RUN_ID=$run -- bash -c 'mark phase:build; make; mark phase:test'
log RUN --stream timeline --marks      # phase:build 0.42s -> 12.8s (12.4s)
```

A tiny `mark` applet writing one named event with the run's own clock. Turns "which phase
was slow" from a reading exercise into a lookup, and needs no ptrace, no /proc, no LD_PRELOAD.

### 9.4 Bounded sample for high-entropy output

`brief` handles repeats; a compiler that says 40 000 different things is immune.

```sh
log RUN --sample 40 --format json     # 40 head, one marker, 40 tail, deterministic
```

### 9.5 Streaming consumption

```sh
run --jsonl -- make -j8    # {"t":1234,"s":"out","line":"…"} per event, flushed
```

For harnesses that want to watch rather than wait; today the JSON document appears only at exit.

### 9.6 Patch application with preconditions

`replace` takes single literals; models emit unified diffs.

```sh
patchapply --dry-run --sha256 pkg.ts=sha256:750d… change.patch --format json
# results:[{path,status,code,changes}] per file, atomic temp+rename, refuses stale input
```

### 9.7 Navigation without reading a file

```sh
outline src/app.ts --format json
# [{name,kind,line,byte,version}] for functions/classes/headings/rules
peek src/app.ts --from-byte 4120    # jumps straight to the body
```

### 9.8 Change detection across runs

```sh
log --diff-timeline R12:R18 --format json   # lines/s, gaps, first stderr, exit delta
```

"Slower than before" answered without a second full read.

### 9.9 Feature advertisement

`--caps .features` still reads `gnu-long-opts,peek,replace,waitfor,run,log,doctor,json`
while the build also has `brief`, `pty`, `timeline`, `brief-json`, `error-ids`, `stamp-ns`.
A client cannot feature-detect what is not listed.

### 9.10 Smaller, already-defined gaps

- `run --help` omits `-n/--stamp-ns` (accepted, undocumented).
- `waitfor --timeout 0` means "one attempt"; `run --timeout 0` means "already expired" —
  consistent only if written down, which this section does.

## 10. How this side verifies the contract now

```sh
./tests/plugin-reports.sh dist/<target>/bin/busybox   # 26 checks, one per reported defect
./tests/agent-ops.sh      dist/<target>/bin/busybox   # 1299 payload/exit-code checks
./tests/streams.sh        dist/<target>/bin/busybox   # 37 stdout/stderr + error-id checks
```

`tests/plugin-reports.sh` is the file to extend when this document gains a defect: each
section (R1…R5) is named after the report it guards, so a regression fails with the reason
attached rather than as a shape mismatch three layers away.
