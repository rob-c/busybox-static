---
title: "Docker daemon recovery: `open -a Docker` and poll `docker info`, do not quit first"
kind: "gotcha"
summary: "When docker info says the daemon is not running, `open -a Docker` plus a 6-second `docker info` poll restores it; quitting Docker Desktop first does not help and can spike load."
tags: [docker, recovery, testing, release, gh]
created: "2026-11-22T13:13:25.168Z"
updated: "2026-11-22T13:13:25.168Z"
---
`open -a Docker` brings the daemon back in about 6 seconds when `docker info` reports "Cannot connect to the Docker daemon at unix:///Users/<user>/.docker/run/docker.sock". Quitting and relaunching Docker Desktop from AppleScript did *not* restore it and briefly pushed host load to ~40, so prefer a plain `open -a Docker` plus a readiness poll.

```text
  docker ps            rc=124, 0 bytes   -> daemon WEDGED   -> open -a Docker, poll
  docker info          "Cannot connect"  -> daemon STOPPED  -> open -a Docker, poll
  gh auth status       rc=124, no output -> host network down -> wait, retry

  open -a Docker
  for i in $(seq 1 20); do
      sleep 6
      timeout 8 docker info >/dev/null 2>&1 && { echo "ready after $((i*6))s"; break; }
  done
```

## Why the distinction matters

There are two different Docker failures and they need different responses. A wedged daemon answers the socket but never replies, so `docker ps` blocks instead of erroring; a stopped daemon fails immediately with "Cannot connect". Only the wedged case ever benefits from a restart, and quitting first is what leaves you in the stopped case.

## Verification after recovery

`docker run --rm -v "$PWD:/w:ro" almalinux:9 bash /w/test.sh /w/dist/linux-arm64/bin/busybox` → "197 passed, 0 failed", and `docker run --rm --platform linux/amd64 -v "$PWD:/w:ro" ubuntu:26.04 bash /w/test.sh /w/dist/linux-amd64/bin/busybox` → "194 passed, 0 failed" (three Zip64 fixtures skip without `python3`). Darwin targets give 198: the APFS `stat -f -c %T` check is Darwin-gated.
