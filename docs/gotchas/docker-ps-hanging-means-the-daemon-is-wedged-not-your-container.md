---
title: "`docker ps` hanging means the daemon is wedged, not your container command"
kind: "gotcha"
summary: "If docker run produces no output, test `docker ps` first: rc=124 with empty output means Docker Desktop's backend is wedged, and restarting it may spike load rather than help; there is no qemu-user fallback on this host."
tags: [docker, testing, blocked, utm, qemu, diagnostics]
created: "2026-11-22T11:40:16.370Z"
updated: "2026-11-22T11:40:16.370Z"
---
When `docker run ... bash test.sh` produces no output and eventually times out, check the daemon before the suite: if `docker ps` itself returns rc=124 with zero bytes, Docker Desktop's backend is wedged and no container command will work. Restarting Docker Desktop from AppleScript did not fix it here and pushed host load from 12.79 to 39.79, so treat that as a last resort, not a fix.

```text
  test.sh hangs in a container
        │
        ├── `docker ps` answers      -> the failure is real; read test.sh output
        ├── `docker ps` rc=124/empty -> Docker backend wedged; restart or wait
        └── `ssh <vm>` fails + `arp -an` empty
                                     -> host virtual networking down too; no fallback
```

## Diagnostic ladder actually used

1. `timeout 60 docker ps >/tmp/ps.out 2>&1; echo rc=$?; wc -c </tmp/ps.out` — rc=124 and 0 bytes means the socket `/Users/<user>/.docker/run/docker.sock` accepts a connection but nothing answers.
2. `timeout 30 docker info --format '{{.ServerVersion}}'` — also rc=124 confirms it is the daemon, not one image.
3. `timeout 90 docker run --rm almalinux:9 /bin/echo hi` — the smallest possible container; still rc=124.
4. UTM fallback: `ssh <name>-vm` resolving to `<name>.local` fails once mDNS is down, `arp -an` is empty, and `dist/darwin-arm64/bin/busybox nc -z -w1 192.168.64.N 22` finds nothing, even though `ifconfig` shows `bridge100`/`bridge101` UP without an inet address.
5. `command -v qemu-aarch64 qemu-x86_64` — if it is absent, a static Linux ELF cannot be executed on macOS at all, so there is no offline fallback for Linux runtime checks.

## Rule

Report Linux verification as **blocked** rather than claiming a pass when `docker ps` does not answer. The commands to rerun afterwards are in `docs/instructions/agent-ops-patches-0006-0008-what-shipped-and-what-is-unverified.md`.
