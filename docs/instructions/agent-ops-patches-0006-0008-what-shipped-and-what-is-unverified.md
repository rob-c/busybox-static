---
title: "Agent-ops patches 0006-0008: what shipped, what is still unverified on Linux"
kind: "instruction"
summary: "Agent ops ship as patches 0006-0008 (json_read, caps, peek, waitfor, replace, run, log, doctor); Darwin is 198/198, Linux runtime verification is still outstanding with the exact rerun commands."
tags: [agent-ops, patches, peek, replace, run, testing, unverified]
created: "2026-11-22T03:54:58.443Z"
updated: "2026-11-22T03:54:58.443Z"
---
The agent-facing feature set from `AGENT-FEATURES.md` is implemented as three patches that apply in series after `0005`, and every one is verified on the three Darwin targets. Linux runtime verification is outstanding: the Linux binaries build and are static, but the applets have not been executed there because this host's Docker Desktop and UTM shared networking both stopped responding mid-session.

```text
  patches/0006-agent-ops-core.patch   json_read, busybox --caps, peek, waitfor   Darwin 198/198
  patches/0007-agent-ops-edit.patch   replace                                     Darwin 198/198
  patches/0008-agent-ops-run.patch    run, log, doctor                            Darwin 198/198
             │
             └── Linux: built (static, 416 applets) but NOT executed here
                        docker Desktop wedged + vmnet-shared unreachable
```

## To close the gap

```sh
docker run --rm -v "$PWD:/w:ro" almalinux:9 bash /w/test.sh /w/dist/linux-arm64/bin/busybox
docker run --rm --platform linux/amd64 -v "$PWD:/w:ro" ubuntu:26.04 \
	bash /w/test.sh /w/dist/linux-amd64/bin/busybox
scp dist/linux-arm64/bin/busybox test.sh <vm>:/tmp/bbtest/ &&
	ssh <vm> 'bash /tmp/bbtest/test.sh /tmp/bbtest/busybox'
```

Expect 197/198 on Linux (the APFS `stat -f -c %T` check is Darwin-gated) and 194/198 in the Ubuntu images, where three Zip64 fixtures self-skip for lack of `python3`. Anything else is a real bug.

## Why it stalled here

`docker run --rm almalinux:9 /bin/echo hi` timed out at 150 s, `ssh alma9-vm` failed with "Could not resolve hostname", `arp -an` returned an empty table, and a port scan of the `vmnet` subnet found nothing - all while host load average sat at 14-19 from unrelated long-running jobs. `bridge100`/`bridge101` were up but carried no address, so there was no path to the guests either.

## State to preserve

- Applets: 269 on Darwin (was 263), 416 on Linux. Binary: 839,488 -> 873,088 bytes (+4.0%).
- `./test.sh` is the single source of truth: 198 checks, with the agent-applet block gated on `busybox --list | grep -qx peek`.
- `./build-all.sh` builds all six targets with `-pure` still libSystem-only.
