# Changelog

Project releases of `busybox-static` on top of upstream busybox
(`1.39.0.git`). The upstream applet set is unchanged except where noted; the
`patches/` series is the record of every local change.

## 0.6.1 — `json --set`/`--delete`, and compact timeline stamps

- **`json` can write.** `json -f FILE -g .a.b --set --value 42` sets a member
  (`--json-value` for a typed value instead of a string) and `--delete` removes
  one, with `--dry-run` printing the result and writing nothing. The document is
  re-serialised only after the edit applies to a parsed tree, so a parse or path
  failure leaves the file untouched.
- **`run -t` stamps are compact.** `[   0.019841 out]` became `[0.019841 out]`:
  the seconds field is unpadded and fractional digits are trimmed, so the same
  information costs fewer bytes per line. `run -t -n` keeps nanosecond
  resolution and still reports `res_ns`.
- **Suite updates** for the trimmed stamp shape (`tests/agent-ops-sweep.sh`
  asserts 1-6 and 1-9 fractional digits rather than a fixed width), and
  `tests/new-applets.sh` covers the JSON writer.

## 0.6.0 — darwin/linux parity, ns timeline, richer run metadata

- **`ip neigh` and `ip tunnel` on Darwin.** `ip neigh` reads the ARP cache through
  `sysctl(NET_RT_FLAGS, RTF_LLINFO)` and `flush` sends `RTM_DELETE` per entry;
  `ip tunnel` creates and configures `gif` clones with `SIOCIFCREATE` and
  `SIOCSIFPHYADDR`. `ip` now accepts and rejects exactly what the Linux applet
  does, case by case, and `ip --help` lists `address|route|link|tunnel|neigh` —
  only `rule` is absent, because it is netlink-only.
- **`run` / `sh --format json` say what happened.** `exit_kind` plus
  `signal`/`signal_name` (a killed child no longer reads as a bare `-1`),
  `argv[]` with real argument boundaries and `argv0_resolved`,
  `cpu_user_ms`/`cpu_sys_ms`/`max_rss_kb` from `wait4`,
  `stdout_lines`/`stderr_lines`/`binary`/`final_newline`/`dropped_bytes`,
  `replay`, `inputs_hash`, `view_next`, `busybox_version`, and the guest shell's
  final `cwd` beside `busybox`'s own absolute path. `-x/--effects` reports the
  files added, changed or removed under the run's cwd.
- **Nanosecond timeline.** `run -t -n` stamps every line and declares the clock's
  real granularity (`res_ns`, measured 41 ns here). Darwin uses
  `CLOCK_MONOTONIC_RAW` because its `CLOCK_MONOTONIC` is 1 µs quantised.
- **Darwin/Linux parity pass.** Option diagnostics are one message owned by
  busybox instead of each libc's own (`getopt32` applets plus `head`, `awk`,
  `hexdump`, `hush`, `rpm`, `unzip`, `dc`, `nmeter`, `ifconfig`); `mount`,
  `umount` and `mkpasswd` help text are identical; `arch` reports `aarch64`.
  Audit result: 451/453 option probes and 111/132 behavioural probes identical,
  with the residue being pruned capabilities and machine data.
- **Patch series re-cut.** Each file is owned by exactly one patch, and
  `tests/patch-reconstruct.sh` proves that applying the series to the upstream
  base reproduces `src/` with 0 differing files.
- **New tooling.** `tests/platform-probe.sh` + `tests/platform-diff.sh` audit two
  binaries probe by probe; `tests/patch-reconstruct.sh` validates the series;
  `tests/agent-ops-sweep.sh` grows to 1300+ checks.

## 0.5.1 — fixes from the plugin's defect reports

- **`run --prune N` works with `--timestamps`.** It unlinked a fixed list
  (`stdout`, `stderr`, `meta`) and then `rmdir` failed on the extra `timeline`
  file, so a wrapped session — which always asks for the timeline — never pruned.
  The directory is now emptied entry by entry: 8 runs with `-t --prune 3` leave 3.
- **`unzip a.zip -d DIR` extracts.** BSD getopt stops at the first non-option, so
  on macOS `-d out` was read as member names: nothing matched and the exit status
  was 0 while the same command worked on Linux. `-d DIR`, `-dDIR` and `-qd DIR`
  are peeled out of argv wherever they appear.
- **The text timeline keeps head *and* tail.** `run -t` printed only the first M
  lines; a failing suite therefore hid its failure at the end and the plugin had
  to spend a retrieval on `log RUN --lines N-40:N`. Three quarters of the budget
  now go to the head, one quarter to the tail, with one marker between.
- **One id per diagnostic.** `--error-ids` printed both `E FAILED` (from
  getopt's option message) and `E USAGE` (from `bb_show_usage`) for a single
  usage error. An unknown option is now marked as a usage error and
  `bb_show_usage` does not repeat an id that already went to stdout.
- **brief's budget hint is true again**: it said `-B 0` meant "no limit" while
  `-B 0` is a zero budget, and `-R` is now documented as literal.
- New `tests/plugin-reports.sh` — 26 checks named after the report each one
  guards. `tests/streams.sh` is 37/37 again.

## 0.5.0 — a real terminal for the guest (`run --pty`)

- `run -Y`/`--pty` launches the guest under a fresh pty: the slave is the child's
  0/1/2, `setsid()` makes the child a session leader and `TIOCSCTTY` makes the
  slave its controlling terminal, so `isatty()`, `tty`, `/dev/tty`, `stty` and
  every full-screen tool behave as they would in a terminal. The master is
  drained like any other stream, so the merged output still lands in the
  `stdout` artifact and the view budgets are unchanged. `--pty-raw` (line
  discipline off), `--pty-split` (stderr keeps its own pipe) and
  `--pty-size COLSxROWS` modify it; `sh --pty` dispatches the whole shell
  through `run --pty`.
- The environment is *not* touched by pty mode: the guest sees exactly the
  variables a pipe run would see (checked byte for byte by the suite), plus the
  parent's terminal size, which the pty inherits when the parent has one.
- stdin is fed through the master (`--stdin FILE`, or a piped parent stdin) and
  terminated with `VEOF` - twice when the input ends mid-line - so line readers
  get a real EOF rather than a hang. Feeding is byte-exact up to the platform's
  canonical line limit; `--pty-raw` is byte-exact beyond it.
- Fixed: `run`'s cancellation was dead code. `bb_signals()` takes `1 << signo`,
  and `run` passed `1 << (signo - 1)`, so the handler was installed on SIGHUP
  and SIGALRM: a SIGTERM to the wrapper killed it outright (128+15) instead of
  recording the cancellation and returning the documented exit 3.
- Fixed: two concurrent runs in the same artifact root could pick the same run
  id and truncate each other's artifacts. The id is now claimed with `mkdir`
  and re-scanned on `EEXIST`.
- New `tests/pty.sh` — 100 checks on the guest's terminal: identity, capture
  fidelity (binary, NUL, 228 KB), the option matrix, stdin feeding and EOF,
  exit codes and deadlines, environment inheritance, JSON/meta surface,
  concurrency, and fd/artifact hygiene. 100/100 on darwin-arm64, darwin-amd64
  (Rosetta), linux-arm64 and linux-amd64.
- `tests/streams.sh` skips `linuxrc`: in a container it swallows `SIGTERM`, so
  the applet sweep could never get past it.

### Also in 0.5.0 — child cleanup when the wrapper is killed

- `run` and `sh` now start a watchdog in its own process group that kills the
  command's group when the wrapper disappears for **any** reason, `SIGKILL`
  included (which cannot be caught). `kill -9` of busybox now stops the work it
  started instead of orphaning it.
- `sh` becomes its own process-group leader when non-interactive, so one group
  kill reaches every child; interactive shells are left alone (job control).
- New `tests/wrapper-signals.sh` — 21 checks: TERM/INT/HUP/KILL against `run`
  and `sh`, guests that ignore TERM, grandchildren, and that ordinary exit
  codes, output and process hygiene are unchanged.
- New `tests/reaper.sh` — 50 checks on the watchdog itself: 5 signals × 3 guest
  shapes per applet, no watchdog left after success or after a kill, no
  premature kill while the wrapper lives, nested wrappers, and three concurrent
  runs stopped at once.
- The watchdog is stopped before the wrapper returns, so it is never visible to
  a process scan of a completed run.

## 0.4.0 — deadline control, output reduction, contract audit

Second agent-facing release. Everything below is carried in `patches/`
(`0004` shell and libbb ergonomics, `0006` core ops, `0008` run/log,
`0015` runlevel) and verified by four suites on darwin-arm64 and, for the
deadline work, in `almalinux:9`.

### Deadlines that hold when the guest fights back

- `run --timeout SECS` exits **3** on expiry, never 124 and never 128+N;
  `--kill-after` (default 2 s) escalates SIGTERM to SIGKILL for the whole
  process group.
- `run --timeout 0` means "the deadline has already passed".
- `sh --timeout SECS` gives the shell the same guarantee. It is implemented by
  dispatching to `run --timeout --quiet` in-process, because ash resets signal
  dispositions while it waits on a child — an in-shell alarm measurably returned
  142/143/158 and could never produce exit 3.
- New `run --quiet`: captured streams only, no summary, so a dispatching
  wrapper is output-identical to a plain shell.

### Output reduction built in

- `run --brief stdout|stderr|both` and `sh --brief [stream]` pipe a stream
  through `brief -d`; `--brief-json` emits brief's schema-1 payload instead of
  the text view, and `run --format json` adds nested `stdout_brief` /
  `stderr_brief` objects.
- `sh --brief` accepts only `stdout`, `stderr` or `both` as a value, so
  `sh --brief script.sh` runs the script instead of eating its name.

### Shell and applet behaviour

- `log --stream timeline` interleaves stdout and stderr by timestamp, with a
  separate printed budget so a small budget shortens the view and not the
  evidence on disk.
- `runlevel` writes its failure diagnostic to stderr (patch 0015).
- `peek -p --format json` now emits `preview` (hex) and `guessed_type`, so a
  binary file is describable instead of merely flagged.
- `replace --sha256` accepts the 12-digit prefix `peek` prints.
- `replace --request` continues past `INVALID_ARGUMENT` but stops on
  `STALE_INPUT`/`NOT_FOUND`, reporting how many edits were skipped.
- `log --stream both --format json` emits two objects instead of text inside
  the array; `log NOSUCH` carries a `message`; `waitfor --timeout 0` performs a
  single attempt.

### Tests

- `tests/streams.sh` — 37 checks on stdout/stderr discipline and error ids.
- `tests/timeout-resilience.sh` — 50 checks: guests that trap TERM, ignore
  TERM/INT/HUP, exit 0 on TERM, leave grandchildren, plus sub-second deadlines.
- `tests/timeout-resilience-matrix.sh` — 200 checks: 10 hostile guests × 4
  invocation paths × 5 assertions. Survivors are found by pid file and
  `kill -0`, because a command-line scan goes blind once the guest exec()s its
  last command; both suites refuse to run unless a deliberately leaked process
  is detected first.
- Existing suites unchanged: `test.sh` 198, `tests/agent-ops.sh` 1299.

## 0.3.0-dev — agent operations (patches 0006-0008)

Adds the agent-facing surface specified in `AGENT-FEATURES.md`: bounded reads
with a truncation cursor, guarded all-or-nothing edits, captured execution with
retrievable artifacts, and readiness polling. Darwin verified; Linux runtime
verification outstanding (see `docs/instructions/agent-ops-patches-0006-0008-what-shipped-and-what-is-unverified.md`).

New applets (269 on Darwin, 416 on Linux):

- `peek` — numbered, byte-budgeted reads with `version=sha256:...`, `--lines`,
  `--around`, `--from-byte` continuation, `--request` batches, binary detection.
- `replace` — literal replacement with `--expect N` match count, `--sha256`
  precondition, `--dry-run`, `--follow` symlink policy, atomic temp+rename.
- `waitfor` — one deadline for `--file`, `--tcp`, `--unix`, `--http` (`--expect`
  status); `https://` is deliberately out of scope.
- `run` / `log` — stdout/stderr captured to 0700 artifacts, process-group
  TERM→KILL, `run=R<n>` ids, retrieval by line range, pattern or `--meta`.
- `doctor` — cwd, executable, temp writability and named tool paths only.
- `busybox --caps [--format json]` — schema, version, platform, arch, applet
  count and compiled-in features.

New libbb module: `json_read` (strict RFC 8259 subset, duplicate keys rejected).

Contract: exit codes 0/1/2/3 only (never 124, never 128+N), `{"schema":1,...}`
for every structured output, and an explicit `truncated`/`next` pair instead of
silent truncation.

Tests: `./test.sh` 168 → 198 checks, all passing on `darwin-arm64`,
`darwin-arm64-pure` and `darwin-amd64`. Binary growth +4.0 % (inside the 5 %
budget); `-pure` still links libSystem only.

## 0.2.x — Darwin port and agent ergonomics (patches 0002-0005)

Port to macOS (263 applets), GNU long options for short-only applets
(`CONFIG_FEATURE_GNU_LONG_OPTS`, 415 rows over 77 applets), and the 0004
ergonomics set: `grep --include/--exclude`, `find -printf`, `printf %q`,
`env -C`, `xargs -d`, `realpath -m`, `mktemp --suffix`, `split -d`, `column`,
ash brace expansion, `${v^^}`, `$SECONDS`.
