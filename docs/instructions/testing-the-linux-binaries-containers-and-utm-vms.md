---
title: "Testing the Linux binaries: Docker (arm64 + Rosetta) and the UTM VMs"
kind: "instruction"
summary: "How to test the Linux binaries on AlmaLinux/Ubuntu containers and the aarch64 UTM VMs, plus the four harness assumptions that made containers and VMs report false FAILs."
tags: [testing, docker, utm, almalinux, ubuntu, rosetta, linux]
created: "2026-11-21T23:43:37.421Z"
updated: "2026-11-21T23:43:37.421Z"
---
The Linux binaries can be tested three ways on this host: Docker Desktop (arm64 native, and amd64 through Rosetta), and the three aarch64 UTM VMs over SSH. All seven target/platform combinations pass `test.sh` with 0 failures, but only after four environment assumptions in the harness were removed — before that, containers and VMs produced five different false FAILs.

```text
  dist/linux-arm64 ──┬─ docker almalinux:9        (native aarch64)  167/0
  (411 applets)      ├─ docker ubuntu:26.04        (native aarch64)  164/0 (3 zip checks skip: no python3)
                     ├─ UTM alma9-vm   (9.8)       aarch64           167/0
                     ├─ UTM alma10-vm  (10.2)      aarch64           167/0
                     └─ UTM ubuntu-vm  (26.04.1)   aarch64           167/0
  dist/linux-amd64 ──┬─ docker almalinux:9 --platform linux/amd64 (Rosetta) 167/0
  (static x86-64)    └─ docker ubuntu:26.04 --platform linux/amd64 (Rosetta) 164/0
  168/0 on Darwin: the extra check is the APFS-only `stat -f -c %T` one.
```

## Commands

```sh
# containers (bind-mount the repo read-only; the binary stays where it was built)
docker run --rm -v "$PWD:/w:ro" almalinux:9 bash /w/test.sh /w/dist/linux-arm64/bin/busybox
docker run --rm --platform linux/amd64 -v "$PWD:/w:ro" ubuntu:26.04 \
	bash /w/test.sh /w/dist/linux-amd64/bin/busybox

# VMs (aarch64 only - no x86 emulation, so the amd64 binary cannot run there)
for h in alma9-vm alma10-vm ubuntu-vm; do
	ssh "$h" 'rm -rf /tmp/bbtest && mkdir -p /tmp/bbtest'
	scp dist/linux-arm64/bin/busybox test.sh "$h:/tmp/bbtest/"
	ssh "$h" 'bash /tmp/bbtest/test.sh /tmp/bbtest/busybox'
done
```

## The four assumptions that had to go

- `ps` row count was asserted as `> 20`; a container PID namespace holds 3. Now compared against the `/proc/[0-9]*` count (with a small tolerance), falling back to the old rule where `/proc` does not exist.
- `pidof`/`killall` were tested on a shell **script**; comm is the interpreter there (see the Rosetta doc). Now tested on an applet symlink (`ln -sf $BB ./sleep`), whose comm is the binary name on every platform.
- `df` read `NR==2`; busybox df wraps a long device name (`/dev/mapper/almalinux-root`) onto its own line, as GNU df does. Now takes the first row whose column 2 is numeric.
- `find -printf %m` expected `644`, but the default umask on AlmaLinux/Ubuntu is `0002`. The fixture is now `chmod 644`'d first.

## Notes

- `ldd` reports "not a dynamic executable" for both Linux binaries — the static-musl claim holds on a real RHEL-family kernel (5.14, 6.12) and on Ubuntu 26.04's 7.0 kernel.
- ubuntu images ship no `python3`, so the 3 Zip64 fixture checks skip themselves (164 vs 167). AlmaLinux containers and all VMs have `python3`.
- A bounded version of `adversarial.sh` section A (388 applets x 2 probes: `--help` and a nonsense option) found no crashes on Linux. The three non-clean results are upstream behaviour reproduced identically on Darwin: `resize` exits 255 without a tty, `nologin` is a scripted applet that `sleep 5`s, `uevent` is a daemon.
- Do not run `adversarial.sh` as root on a real VM: its `SKIP_MATRIX` does not include `reboot`/`poweroff`/`halt`/`init`, and all four are enabled in the Linux build (411 applets), so the "devnull" probe would call `reboot(2)` for real.
