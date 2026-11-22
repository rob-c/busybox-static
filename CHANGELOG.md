# Changelog

Project releases of `busybox-static` on top of upstream busybox
(`1.39.0.git`). The upstream applet set is unchanged except where noted; the
`patches/` series is the record of every local change.

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
