# Agent-facing features for `busybox-static`

**Status: implemented** as `patches/0006`-`0008` (one patch per tier), tested by
`./test.sh` on every target. This document is kept as the design record: what was
built, what changed during implementation, and what was deliberately left out.
It takes the external "agent-focused BusyBox" brief, keeps the parts that belong
in *this* tree, drops the parts that belong to a Pi plugin or that cannot be made
cross-platform, and specifies the constraints this repository has already paid
for.

**Cross-platform here means:** one source tree and identical behaviour across
`linux-amd64` / `linux-arm64` (static musl ELF) and `darwin-arm64` /
`darwin-amd64` (Mach-O, libSystem-only in the `-pure` variants). A feature that
needs `#ifdef`-per-platform *behaviour* is not cross-platform; one that needs a
platform shim behind a single API (like the existing `getmntinfo` wrapper or the
`ppoll` emulation) is.

**Not in scope:** the Pi extension and any model-facing tool wiring (separate
project), MCP, job daemons, AST/embedding indexes, automatic checkpoint
restore.

**Delivered as three patches**, one per tier, each applicable in series after
`0005` and droppable without touching 0002-0005:

| patch | tier | files |
|---|---|---|
| `0006-agent-ops-core.patch` | P0 | `include/json_read.h`, `libbb/json_read.c`, `libbb/appletlib.c`, `coreutils/peek.c`, `miscutils/waitfor.c` |
| `0007-agent-ops-edit.patch` | P1 | `editors/replace.c` |
| `0008-agent-ops-run.patch` | P2 | `coreutils/run.c`, `miscutils/doctor.c` |

Measured on the delivered build: 269 Darwin applets (was 263), 416 on Linux (was
410), Darwin binary 839,488 -> 873,088 bytes (+4.0%, inside the 5% budget),
Linux arm64 1,305,504 -> 1,340,448 (+2.7%), ~3,730 lines of new C. `test.sh`
went from 168 to 198 checks.

---

## 1. Why this tree is the right host

What an agent gets from `dist/<target>/bin/busybox` today:

* **411 applets** on the Linux builds, **263** on Darwin (measured;
  `README.md`'s table says 410 because it predates the `column` applet).
* **Truly static on Linux** (`ldd` → "not a dynamic executable") and
  **libSystem-only** on macOS in the `-pure` variants.
* `0003` gave applets GNU long options, so an agent's habitual
  `du --max-depth=1`, `grep --line-number`, `stat --format=%s` works in both
  binaries instead of failing on the Darwin one.
* `0004` closed the specific idioms agents write wrongly: `grep
  --include/--exclude/--exclude-dir/--exclude-from`, `find -printf`, `printf %q`,
  `env -C`, `xargs -d`, `realpath -m`, `mktemp --suffix`, `split -d`, `column`,
  ash brace expansion, `${v^^}`, `$SECONDS`.

What is still missing is not *more commands* — it is the **contract**: bounded
output, an explicit truncation cursor, machine-readable errors, and a versioned
read/write pair. That is the entire value of this proposal, and it is what makes
an agent's second call cheaper than its first.

## 2. The shared contract

Every applet in this proposal obeys the same rules. Where a rule has a busybox
mechanism, it is named.

| Rule | Busybox mechanism |
|---|---|
| Human text by default, `--format json` on request; JSON is never the only output | `getopt32long()` (`include/libbb.h:1557`) — new applets get long options natively and need no row in `libbb/gnu_longopts.c` |
| Structured output has a versioned schema (`"schema":1`) and stable field names | literal strings in the `.c` file; no shared registry |
| Every output limit is explicit, and truncation is reported with a continuation cursor | byte budgets, `shown_bytes`/`truncated` in text, the same as fields in JSON |
| Byte budgets, never "token counts" | busybox has no tokenizer and must not claim one |
| Distinct, documented exit codes; existing applets keep POSIX semantics | `xfunc_error_retval` (`include/libbb.h:1628`) |
| No prompts, pagers, animation or ANSI in structured output | plain `full_write*` |
| Never silently retry a mutation, never fuzzy-match, never substitute an operation | preflight-then-write, no retries |
| Spaces, Unicode, CRLF, missing final newline, odd filenames treated as bytes | byte-oriented `open`/`read`, never `fgets` for content |

Error codes carried in JSON (exit codes stay coarse, 0–125):

```
INVALID_ARGUMENT  NOT_FOUND  STALE_INPUT  AMBIGUOUS_MATCH
TIMEOUT  CANCELLED  CAPTURE_INCOMPLETE  UNSUPPORTED
```

Exit codes, identical for every new applet:

| code | meaning |
|---|---|
| 0 | success (including "read completed, output truncated" — truncation is data, not failure) |
| 1 | operation failed (not found, ambiguous, stale, invalid argument) |
| 2 | usage error (bad option/arity) |
| 3 | timeout or cancellation |

Never 124, never 128+N. `timeout` itself exits `128+signal` here
(`docs/gotchas/timeout-exits-128-plus-signal-not-124.md`), which is exactly why
these applets must own their own deadlines instead of delegating.

## 3. Build list

| # | command | shape | tier | est. size | blocked by |
|---|---|---|---|---|---|
| 1 | `busybox --caps [--format json]` | extend the `busybox` applet | **P0** | <1 KB | — |
| 2 | `peek` | new applet (text mode only) | **P0** | 6–10 KB | — |
| 3 | `waitfor` | new applet | **P0** | 4–8 KB | — |
| 4 | `replace` | new applet | **P1** | 8–12 KB | — |
| 5 | `libbb/json_read.c` | new libbb module | **P0** | 8–14 KB | — |
| 6 | `peek --request` (batch) | verb on `peek` | **P0** | +3–5 KB | 5 |
| 7 | `run` / `log` | new applet | P2 | 18–30 KB | 5 for `--request`, none for CLI |
| 8 | `doctor` | new applet | P2 | 3–5 KB | — |

Sizes are estimates scaled from comparable applets, using their own Kconfig
figures as the (rough) yardstick: `column` 2.6 KB, `fallocate` 4.3 KB, `flock`
6.5 KB, `timeout` 6.5 KB. Measure with the method in §7 before claiming anything.

Deferred and rejected items are in §9 — read that before proposing more.

---

## 4. Specifications

### 4.1 `peek` — bounded, numbered, versioned reads (P0)

```sh
busybox peek FILE --lines 120:180
busybox peek FILE --around 'handleConnection' --context 20
busybox peek FILE --lines 1:2000 --max-bytes 16000
busybox peek FILE --from-byte 2841 --max-bytes 16000      # continuation
```

Text output (one line of header, one line per source line, one line of footer):

```
src/server.ts lines=120-180 version=sha256:9b2c… shown_bytes=2841 truncated=false
120 | int handleConnection(int fd) {
```

**Rules**

* Ranges are 1-based and inclusive; `--lines 7` means line 7 only.
* `--around` is a **literal** string match; regex only via `--regex`.
* Multiple `--around` windows merge when they overlap or touch, and the merged
  window is reported as one range. Windows are not re-scanned after merging.
* `--max-bytes` caps the *returned* bytes, not the scanned ones. Cut on a line
  boundary, and never mid-UTF-8-sequence (back off trailing continuation bytes).
* `truncated=true` comes with `next=--from-byte N` so the caller can continue
  without silently skipping lines.
* `version=sha256:…` is the hash of the **whole file as read**, computed over the
  same buffer that produced the output (`sha256_begin`/`sha256_hash`/
  `sha256_end`, pure C, `include/libbb.h:2399-2401`; Darwin's SHA hardware
  acceleration is off in this build, so the code path is identical everywhere).
  Newlines are *not* normalised: a CRLF file hashes its CRLF bytes.
* Binary input (a NUL in the first 8 KiB, or >30% non-text control bytes) is
  reported, not dumped: `binary=true guessed_type=application/octet-stream`,
  with a hex preview of the first 64 bytes via `od`-style formatting.

**Implementation notes**

Read with `xmalloc_open_read_close()` / `full_read()`; `fstat` first to size the
buffer. All offsets are `size_t` over the raw buffer; line numbering is a
`memchr` scan, so a 100 MB file is one pass, not one `getline` per line.

**Done when:** overlapping windows merge, the byte budget is respected exactly,
`--from-byte` continues with no gap, the hash changes when the file changes, a
NUL-containing file is flagged instead of dumped, and a CRLF file round-trips
through `replace` unchanged.

### 4.2 `replace` — guarded, all-or-nothing editing (P1)

```sh
busybox replace FILE --old 'const timeout = 1000;' --new 'const timeout = 5000;' --expect 1
busybox replace FILE --old … --new … --sha256 9b2c… --dry-run
```

**Rules**

* Match is **literal bytes**; `--regex` is explicit and never the default.
* `--expect N` (default 1) is checked *before* any write. 0 matches → exit 1
  `NOT_FOUND`; N+1 matches → exit 1 `AMBIGUOUS_MATCH` with the candidate line
  numbers; the file is untouched in both cases.
* `--sha256` (from `peek`) is a precondition: mismatch → exit 1 `STALE_INPUT`,
  file untouched.
* **All edits are validated against the original buffer.** Replacements are
  computed into a new buffer from original offsets, so one replacement can never
  match text produced by another (no chaining), and overlapping replacements are
  rejected as `INVALID_ARGUMENT`.
* `--dry-run` writes nothing and prints a bounded unified diff (reuse `diff`'s
  emitter where practical, otherwise a plain `-`/`+` dump capped by
  `--max-diff-bytes`).
* On success: print the same bounded diff plus `version=sha256:<new>`.
* Symlinks are **refused** by default (`--follow` to opt in). This is a
  deliberate divergence from `sed -i`, which replaces the link with a regular
  file (`editors/sed.c` `stat()`s the target, then renames the temp over the
  path).
* Preserve mode and owner: copy the existing `sed -i` idiom exactly —
  `xasprintf("%sXXXXXX")` + `xmkstemp` in the same directory +
  `fchmod`/`fchown` + `fflush` + `ferror` check + `xrename`
  (`editors/sed.c:1640-1664`; `xmkstemp`/`xrename` are `include/libbb.h:733,736`).
  `xmkstemp` creates 0600, so a crash mid-write cannot leave a world-readable
  partial file.
* Durability: `fsync` the temp fd before the rename; wrap in
  `#ifdef F_FULLFSYNC` for Darwin, where plain `fsync()` does not flush to media.
* Concurrency: take an exclusive `flock()` on the target (the same call the
  `flock` applet uses) for the validate→write window, and re-check `--sha256`
  **under** the lock.
* Documented limitation, stated in `--help` and in the error text: this
  coordinates cooperating writers only. It is not a guarantee against an
  external editor that ignores `flock`, and multi-file preflights are not a
  transactional commit.

**Done when:** missing, ambiguous, stale and overlapping edits all leave the file
byte-identical; `--dry-run` never writes; a successful edit preserves unrelated
bytes, mode and owner; the version from `peek` is rejected after an outside
write.

### 4.3 `waitfor` — bounded readiness polling (P0)

The name is not cosmetic. An applet called `wait` is unreachable from a script in
both shells in this binary (verified: `sh -c 'wait --tcp …'` → `illegal option`,
rc 2; `hush` → `not a pid or valid job spec`). Use `waitfor`.

```sh
busybox waitfor --file /tmp/ready --timeout 20
busybox waitfor --tcp 127.0.0.1:8080 --timeout 20
busybox waitfor --unix /tmp/app.sock
busybox waitfor --http http://127.0.0.1:8080/health --expect 200 --timeout 20
```

* One overall deadline (`monotonic_us()`, `include/libbb.h:458`), a poll interval
  that backs off 20 ms → 200 ms, and a per-attempt connect timeout of 1 s.
* `--file` is a `stat`, not an open.
* `--tcp` is a real `connect()`; success means *the port accepts connections*,
  not that the application is ready — say so in `--help`.
* `--http` does its own HTTP/1.1 GET with `xhost2sockaddr()` + `poll()`, so the
  status code is observable and `--expect CODE` works. **Implemented for `http://`
  only**: `https://` exits with "use `wget --spider`", because a correct TLS
  client is not something to hand-roll here and `wget --spider` cannot report a
  status code. This is the one place the plan changed during implementation —
  the earlier idea of spawning `wget --spider` would have lost `--expect` and,
  on Darwin, could not spawn at all: `CONFIG_BUSYBOX_EXEC_PATH` is
  `/proc/self/exe` there, which does not exist.
* Signal-aware waiting so `^C` is prompt — use `safe_poll()`/the `ppoll()`
  emulation in `libbb/poll_with_signals.c`, not a bare `sleep` loop.
* Exit 0 on success, 3 on deadline/cancel, 1 for invalid input.

### 4.4 `busybox --caps [--format json]` (P0)

Extend the `busybox` applet's own option block (`libbb/appletlib.c:791`) rather
than adding a new applet: it already owns `--list`, `--list-full`, `--show`,
`--install`.

```json
{"schema":1,"version":"1.39.0.git","platform":"linux","arch":"aarch64",
 "features":["gnu-long-opts","agent-ops"],"applets":["…"],"count":411}
```

`features` must be computed from `ENABLE_*` macros, not hard-coded, so a build
cannot advertise something it lacks. `applets` is the existing `--list` output.

**Why not `help --json` for every applet:** busybox has no structured option
metadata — usage text is a free-form string generated into `include/usage.h`.
A JSON option table would be a hand-maintained duplicate that drifts. Each *new*
applet in this proposal embeds its own small description struct next to its code
instead.

### 4.5 `run` / `log` — captured execution with retrievable evidence (P2)

```sh
busybox run --timeout 120 --max-bytes 12000 -- python -m pytest
busybox run --shell --timeout 60 -- 'make -j8 > build.log 2>&1'
busybox log R7 --match 'FAILED|Traceback' --context 8
busybox log R7 --lines 200:280 --stream stderr
```

* Arguments are exec'd verbatim (`spawn`), a separate explicit `--shell` mode
  goes through the built-in ash. Never both.
* stdout and stderr go to **separate artifacts** (0600 files under a 0700
  `mkdtemp` directory; `$TMPDIR` on macOS is already per-user, `/tmp` on Linux is
  0777, so the directory mode is what protects them). Cross-stream interleaving
  is not recorded and must not be implied.
* The returned view is head+tail of the captured bytes, bounded by
  `--max-bytes`; the artifact keeps everything. **View truncation and capture
  incompleteness are separate fields**: `view_truncated` vs `capture_complete`.
  Exceeding the capture quota sets `capture_complete=false` and keeps draining
  (or kills the child deliberately) — a child blocked on a full pipe is a bug.
* Metadata: `run_id`, `argv`, `cwd`, `duration_ms`, `exit_code`, `timed_out`,
  `signal`, `cancelled`. No environment dump, ever.
* Deadline and cancellation are owned here, not delegated to `timeout`, because
  `timeout` cannot distinguish "timed out" from "child died of SIGTERM"
  (`docs/gotchas/timeout-exits-128-plus-signal-not-124.md`). Use `setsid()` +
  `killpg()` with TERM → grace → KILL (`-k` semantics), on both platforms.
* Documented limitation: a grandchild that detaches from the process group
  escapes. Linux has subreapers (`PR_SET_CHILD_SUBREAPER`), Darwin does not — do
  not use it, or the behaviour stops being cross-platform.
* `log` is a verb, not a paid feature: it only reads artifacts under the run
  directory, by line range or pattern±context, with `--stream`.
* Retention: `--keep N` runs (default 10), sweep by mtime at the start of each
  `run`; never follow symlinks when sweeping.

This is the item with the largest accidental scope, and the one to build last. If
in doubt, ship `peek` + `replace` first and re-evaluate whether `run`/`log` earn
their keep.

### 4.6 `doctor` (P2)

Reports cwd, `argv[0]` resolution, the shell busybox would use, writable temp
storage (probe with `mkstemp`, then unlink), and a short list of explicitly
selected dependencies (`git`, `make`, `python3`) by path only. Never the full
environment, never a variable's value — names only, or nothing.

### 4.7 `batch` — read-only, shared budget (P1, after §5)

`peek --request REQ.json` with several entries: per-entry `id`, per-entry status,
one shared byte budget consumed in request order, and `unprocessed:[ids]` for
entries the budget did not reach. Cancellation stops at an entry boundary so the
caller can resume deterministically. Mutations are excluded for now: `replace`
takes one file so its failure modes stay comprehensible.

---

## 5. The one foundation: `libbb/json_read.c`

Four of the features above take JSON *input*, and this tree has no JSON parser at
all (`rg -l -i json src/` finds only `lsblk.c` and `ip_parse_common_args.c`).
Emitting JSON is `printf`; parsing it is the only real dependency in this plan.

**Spec:** strict RFC 8259 subset — objects, arrays, strings with `\uXXXX`
(including surrogate pairs), `true`/`false`/`null`, and numbers kept as their
literal text. Reject: comments, trailing commas, single quotes, unquoted keys,
NaN/Infinity, duplicate keys (config files especially). Depth limit 32, input
size limit configurable by the caller.

```c
enum { JSON_MAX_DEPTH = 32 };
struct json_value;                                  /* tagged union + children */
struct json_value *json_parse(const char *buf, size_t len, char **err);
const struct json_value *json_get(const struct json_value *obj, const char *key);
const char *json_str(const struct json_value *v, const char *dflt);
long json_int(const struct json_value *v, long dflt);
void json_free(struct json_value *v);
```

Keep it a *reader*: no pretty-printer, no path expressions, no jq clone. The
secondary "`json set config.json /server/port --value 8080`" idea from the brief
is deliberately out of scope until a real caller exists (§9).

Rejected alternative: a bespoke line-oriented request format. Cheaper, but it
contradicts the one interface every agent already knows, and any hand-rolled
escaping rule turns filenames with spaces or quotes into a bug.

---

## 6. Rules the implementation must obey

### 6.1 Portable by construction

Use: `open`/`read`/`fstat`/`ftruncate`/`rename`/`unlink`, `mkstemp`/`mkdtemp`,
`flock`, `fork`/`spawn`, `waitpid`, `setpgid`/`setsid`/`killpg`,
`clock_gettime(CLOCK_MONOTONIC)`/`monotonic_us()`, `poll`/`ppoll` (emulated for
Darwin in `libbb/poll_with_signals.c`), `sha256_*`, and the usual `libbb`
helpers (`full_read`, `full_write`, `safe_poll`, `xasprintf`, `xmkstemp`,
`xrename`, `xmalloc_fgetline`).

Never: `/proc`, netlink, `inotify`, `ioctl(BLK*)`, `O_TMPFILE`, `renameat2`,
`copy_file_range`, `splice`, `sendfile`, `prctl`, `pidfd_*`, `eventfd`. Each of
these would make one target a second-class build, and §6.3's gotchas exist
because the repo already tried.

### 6.2 Darwin specifics that touch these features

* `fsync()` does not flush to media; `fcntl(F_FULLFSYNC)` does — `#ifdef` it.
* `st_mtim` vs `st_mtimespec` is already macro'd in `include/platform.h`; use the
  macro, never the literal field.
* `$TMPDIR` may be `/var/folders/…`; never assume `/tmp` is safe.
* No subreaper: detached grandchildren reparent to `launchd` and are gone. State
  it, don't fake it.
* No static libc: the Darwin binaries are dynamic by necessity
  (`docs/discoveries/static-macos-binaries-are-impossible-*`). "Cross-platform"
  is about source and behaviour, not file format.

### 6.3 Busybox mechanics (read these before writing code)

* **A new applet is one `.c` file** carrying `//config:`, `//applet:`,
  `//kbuild:` and `//usage:` blocks — `util-linux/column.c` is the working
  precedent. No central table, so none of the `find -printf` params-ordering or
  `getopt32` bit-position traps from `README.md`.
* **New applets call `getopt32long()` directly**, so they need no row in
  `libbb/gnu_longopts.c` (that table exists for legacy short-only applets).
* **`getopt32()` calls `bb_show_usage()` on a bad option**
  (`libbb/getopt32.c:600`), which exits before your code runs. A `--format json`
  mode must pre-scan `argv` for the flag, or a bad option escapes as text on
  stderr.
* **Exit codes** go through `xfunc_error_retval` (`include/libbb.h:1628`); set it
  early, not at the end.
* **Enable the new CONFIG symbols in `build.sh`'s `EXTRA_CONFIG`**, never only in
  `build/<target>/.config` — `build-all.sh` wipes build directories
  (`docs/gotchas/enabling-a-darwin-applet-in-a-build-config-is-lost-by-build-all.md`).
* **Add a `CONFIG_*` line to `prune/darwin-off.txt` only if the applet is
  genuinely Linux-only.** None of the applets here are.
* **Platform shims go in new files**, never in `include/platform.h` or
  `libbb/platform.c`, which 0002/0003 own.
* **Kbuild gate** if a symbol ever pulls in a whole library (the `ip`/netlink
  precedent, `docs/gotchas/porting-ip-to-darwin-needs-a-kbuild-gate-not-just-an-ifdef.md`).
* **GPLv2:** these binaries ship with patched source plus the build scripts on
  every release (`docs/rules/publishing-these-binaries-requires-gplv2-source-scripts-busybox.md`).
  A droppable `0006` keeps that honest.

---

## 7. Size budget, and how to measure it

Growth target: **≤ 5% per binary** (Darwin arm64 is 839,488 bytes, Linux arm64
1,305,504 bytes today, so ~40 KB and ~65 KB). The whole table in §3 fits.

Measure the way `gnu_longopts` was measured: build before and after, then report
Mach-O `__cstring`/`__text` deltas and total file size (`size -m`, `otool`,
`stat -f%z`), and state the numbers in the commit message. Do not guess — the
704-byte figure for 415 long-option rows in `README.md` is the house standard for
this kind of claim.

## 8. Testing

* **Unit-ish coverage in `test.sh`** (its `ck` helper), one check per rule above:
  window merging, `--from-byte` continuity, hash-after-change, binary detection,
  CRLF round-trip, ambiguous/stale/all-or-nothing `replace`, `--dry-run` writes
  nothing, mode/owner preserved, symlink refusal, `waitfor` success and deadline,
  `--caps` counts matching `--list`, `run` exit-code passthrough, and
  `capture_complete` vs `view_truncated` being independent.
* **Matrix**: `darwin-arm64`, `darwin-amd64` (via `arch -x86_64`), both `-pure`
  variants, `linux-arm64`/`linux-amd64` in `almalinux:9` and `ubuntu:26.04`
  containers (amd64 through Rosetta) and the aarch64 UTM VMs. The exact commands
  and the four harness assumptions to avoid are in
  `docs/instructions/testing-the-linux-binaries-containers-and-utm-vms.md`.
* **Regression floor**: 168 checks on Darwin, 167 on Linux, 164 in the Ubuntu
  containers (three Zip64 fixtures skip without `python3`) — all must stay at 0
  failures.
* **Identical behaviour across platforms is the test**, not just "it compiles":
  every new check runs on both, and any check that cannot is a design smell.

## 9. Not doing, and why

| Idea from the brief | Verdict | Reason |
|---|---|---|
| Pi extension, tool-result wiring | **out of scope** | separate project (see "Not in scope" at the top) |
| MCP server, persistent jobs, checkpoint restore | **rejected** | daemons and state in a 1-file multicall binary; the brief says so too |
| Naming an applet `wait` | **rejected** | shadowed by both shells' builtins (verified) |
| `help --json` for *existing* applets | **rejected** | no structured option metadata; would be a drifting duplicate |
| Full `jq` clone / `json set` | **deferred** | no caller yet; `json_read.c` is enough for `--request` |
| Search wrapper with byte budgets | **deferred** | `grep -rl` is 13× slower than `rg` in this binary (`docs/discoveries/what-agent-written-shell-hits-in-this-binary-*`); a budget wrapper improves the contract but not the reason an agent reaches for `rg` |
| Selective test/lint output reduction | **deferred** | format-specific heuristics; high churn for a marginal win. Revisit after `run`/`log` show which formats actually dominate |
| `repo` inventory / inferred build commands | **deferred** | cheap to write, but it duplicates `find`+`stat` and guesses at commands the calling tool is better placed to decide |
| Checked patches (`patch --dry-run` + bounded diff) | **mostly free** | busybox `patch` has no fuzz knob at all, so "no fuzzy apply" already holds; no new work until a real gap appears |
| Exact token counts | **rejected** | no tokenizer in the binary |

## 10. Open questions

1. **Schema versioning**: one `"schema":1` per applet, or one suite-wide constant
   bumped together? (Recommendation: per applet, so `peek` can evolve without
   invalidating `run`.)
2. **Artifact root**: `$TMPDIR/busybox-run` vs a caller-supplied `--dir`? Retention
   is meaningless for artifacts the caller already deleted.
3. **`run` capture**: pipes (binary-safe, no ordering) vs a pty (ordering, but
   injects `\r\n` and breaks binary output). Recommendation: pipes only, and say
   so.
4. **`batch`**: a verb on `peek`, or its own applet? Start as a verb.

## 11. What changed during implementation

* `libbb/json_read.c` moved from P1 to P0, because `peek --request` needs it and
  splitting one file across two patches is not worth it.
* `waitfor --http` handles `http://` with its own GET instead of `wget --spider`
  (status codes, and no `/proc/self/exe` on Darwin) - see 4.3.
* `run --shell` execs the busybox shell through `bb_busybox_exec_path` and falls
  back to `sh` from `PATH`; on Darwin the first attempt cannot work for the same
  `/proc/self/exe` reason.
* `replace --follow` resolves the link with `realpath()` before writing, so the
  link survives. The first implementation reproduced the `sed -i` bug (link
  replaced by a regular file) and the `replace: --follow works` check caught it.
* `run` reads the child's streams through pipes and always drains them, even past
  `--capture-limit`, so a full pipe can never block the child.

## 12. First three commits

1. `libbb: add json_read` — the parser plus `test.sh` cases (no user yet), so the
   foundation is reviewed before anything depends on it.
2. `busybox: --caps [--format json]` + `peek` (text mode) — smallest end-to-end
   demo of the contract: bounded output, truncation cursor, version hash.
3. `replace` — the only feature here that makes the *write* path safer rather
   than just the read path, built on `sed -i`'s existing temp+rename idiom.

```text
   new applets (one .c each, //config //applet //kbuild //usage)
        peek   replace   waitfor   run/log   doctor
          │       │         │        │         │
          └───────┴─────────┴────────┴─────────┘
                          │
                libbb: json_read (+ shared file helpers, if any)
                          │
        POSIX + existing libbb helpers (--pure-safe, static-safe)
                          │
     linux-arm64/amd64 (musl, static)   darwin-arm64/amd64 (libSystem)
```
