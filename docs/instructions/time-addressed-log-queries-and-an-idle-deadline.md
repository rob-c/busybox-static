---
title: "Time-addressed log queries and an idle deadline are implemented"
kind: "instruction"
summary: "`log --since/--until/--around-gap/--summary/--sample/--diff-timeline` and `run --idle-timeout` shipped; five of nine §9 proposals done, four (mark, jsonl, patchapply, outline) still proposals."
tags: [run, log, timeline, idle-timeout, patch-0006, patch-0008]
created: "2026-11-23T17:19:50.188Z"
updated: "2026-11-23T17:19:50.188Z"
---
Five of the nine contract proposals now exist in the working tree: time-windowed timeline retrieval, a summary digest, a bounded sample, an idle deadline, and cross-run shape comparison — plus `--caps` advertising them. Four remain proposals (`mark` applet, `run --jsonl`, `patchapply`, `outline`).

```text
  log RUN --stream timeline --since 0.2 --until 3.4 --format json
        {"events":[{"n":3,"us":319758,"stream":"out","text":"c"}], …}
  log RUN --stream timeline --around-gap 0.1 --limit 3   gaps:[{from_us,to_us,gap_us,before,after}]
  log RUN --summary --format json
        {"lines":3,"stderr_lines":1,"first_out_us":8286,"first_err_us":166025,
         "longest_gap":{…},"exit_code":0,"duration_ms":319,"timed_out":false}
  log RUN --sample 1 --format json        {"lines":["a"],"omitted":0,"tail":["c"]}
  log --diff-timeline R1:R2 --format json {"changed":true,"lines":{"a":3,"b":2},…}
  run --idle-timeout 1 -- sleep 20        exit 3, idle=true, output kept
```

## Traps met while wiring them

- **`getopt32long` bits are positional.** Adding `S:U:G:N:P:ZQ:` shifted nothing, but counting `Z` from the end gave `1 << 17` (wrong) instead of `1 << 13`; the symptom was `--summary` silently answering with the ordinary stream view. Count the letters in the optstring.
- **Helper order matters.** New functions calling `read_all`/`line_starts`/`art_path` must sit *after* those definitions; inserting them at the section banner compiled only after moving the block below the utilities.
- **Two header printfs.** `run` prints its summary line in both the timeline branch and the pipe branch; adding `idle=` to one leaves the other reporting `timed_out=false` with no explanation.
- **The idle clock must be the last *data* byte**, not the last poll: a guest that prints every 0.4 s with `--idle-timeout 2` must complete (it does), while `sleep 20` with no output dies at 1 s (it does).
- **A sample's omitted count depends on the stream**: `--sample 1` on a stdout artifact of 2 lines omits 0, which the first version of the test asserted as 1.

## Verification

`tests/timeline-query.sh` — 35 checks in seven sections (Q1–Q7), each pinning one shipped item. Alongside: `test.sh` 198, `agent-ops` 1299, `agent-ops-sweep` 1267, `streams` 37, `plugin-reports` 26. Patches `0006` and `0008` regenerated and reverse-checked; `patchcheck` → `checked=21 bad=0`.
