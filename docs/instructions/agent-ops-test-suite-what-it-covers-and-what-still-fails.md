---
title: "Agent-ops test suite: 1300+ cross-platform checks, green on Darwin and Linux"
kind: "instruction"
summary: "tests/agent-ops.sh is green: 1299 checks on darwin-arm64 and 1318 on almalinux/ubuntu containers; the 15 original failures were harness assumptions, listed here with their fixes."
tags: [tests, agent-ops, cross-platform, green, harness-traps, peek, replace, run]
created: "2026-11-22T13:22:30.001Z"
updated: "2026-11-22T13:31:49.047Z"
---
The suite is green: `tests/agent-ops.sh` reports **1299 passed / 0 failed** on `darwin-arm64` and **1318 passed / 0 failed** on both `almalinux:9` (arm64) and `ubuntu:26.04` (amd64 via Rosetta). All 15 original failures were harness assumptions, not binary defects — this note records what each one taught, because the same mistakes are easy to repeat in any new check.

```text
  failure                     cause                        fix
  log.lines.*          (7)     hard-coded R259 ids          derive from $TMPDIR/r listing
  batch.count/.ok      (2)     grep -c counts LINES         grep -o ... | wc -l
  run.capture.limit    (1)     --format after --            move option before --
  waitfor.bad.args     (1)     expected exit 1              argument errors exit 2
  log.match.*          (2)     --match is literal           match a real substring
  log.stream.both      (1)     BRE \\| unsupported           grep each header separately
  batch fixture drift  (1)     shared fixtures              private files per section
```

## The six traps

- **Hard-coded run ids.** `run` numbers artifacts `R<n>` by scanning the directory, so any earlier `run` shifts every later id. Derive it: `rid="$(cd "$TMPDIR/r" && "$BB" ls | "$BB" sort -V | "$BB" tail -1)"`.
- **`grep -c` on JSON counts lines.** Structured output is one line, so the count is always 1. Use `grep -o ... | wc -l`.
- **`--format` after `--` becomes a child argument.** Put options before `--`.
- **`wc -l` may arrive space-padded.** Pipe through `tr -d ' '`, and derive expectations with `seq 1 N` rather than literals.
- **`--match` is literal**, and the default `--context 3` means the first printed line is not the match line.
- **Applets `[` and `[[` contain `]`**, so a `sed 's/.*"names":\[//; s/\].*//'` truncates the name list; compare `"count"` against `"$BB" --list | wc -w`.

## Reproduce

```sh
./tests/agent-ops.sh dist/darwin-arm64/bin/busybox                     # 1299
docker run --rm -v "$PWD:/w:ro" almalinux:9 \
	bash /w/tests/agent-ops.sh /w/dist/linux-arm64/bin/busybox        # 1318
```
