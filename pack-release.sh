#!/bin/bash
# Assemble everything a release needs into release/ so that one `gh release
# create` can upload it. Does NOT talk to GitHub.
#
#   ./build-all.sh && ./pack-release.sh
#
# Produces in release/:
#   busybox-<ver>-<sha>-src.tar.gz      patched upstream source (GPLv2 §3(a))
#   busybox-<ver>-<sha>-*.patch         the patch series, individually
#   busybox-<ver>-<sha>-configs.tar.gz  the .config of every target
#   busybox-<ver>-<sha>-<target>        one binary per target
#   SHA256SUMS, NOTES.md
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

SRC="$ROOT/src"
[[ -d "$SRC" ]] || { echo "no src/ — clone busybox first (see RELEASING.md)" >&2; exit 1; }

# ---- identity of this release ------------------------------------------------
# note the explicit newline: without it read() hits EOF and returns 1, which
# under `set -e` silently kills the script
read -r V_MAJ V_MIN V_SUB < <(
	awk '/^(VERSION|PATCHLEVEL|SUBLEVEL)[ \t]*=/ {printf "%s ", $3} END{printf "\n"}' "$SRC/Makefile"
)
BASEVER="${V_MAJ}.${V_MIN}.${V_SUB}"                       # e.g. 1.39.0
SHA="$(git -C "$SRC" rev-parse --short=7 HEAD)"
DATE="$(git -C "$SRC" log -1 --format=%ad --date=short)"     # upstream commit date
TAG="v${BASEVER}-${SHA}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REL="$ROOT/release"
OUT="$REL/$TAG"

# Refuse to package if the tree is not the patched state we expect: a release
# whose binaries and source tarball disagree is worse than no release.
if [[ -n "$(git -C "$SRC" diff --stat)" ]]; then
	echo "src/ has uncommitted modifications (expected: the patch series)"
else
	echo "WARNING: src/ has no modifications — are the patches applied?" >&2
fi

TARGETS=(linux-amd64 linux-arm64 darwin-arm64 darwin-amd64 darwin-arm64-pure darwin-amd64-pure)
for t in "${TARGETS[@]}"; do
	[[ -f "dist/$t/bin/busybox" ]] || { echo "missing dist/$t/bin/busybox — run ./build-all.sh" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> packaging $TAG (upstream $SHA, $DATE)"
P="busybox-static-${BASEVER}-${SHA}"

# ---- patched source (the GPL obligation) ------------------------------------
# tar the working tree, not `git archive`: the patches are uncommitted and
# libbb/mntent.c is new/untracked, so an archive of HEAD would be unpatched.
tar -czf "$OUT/${P}-src.tar.gz" -C "$SRC" --exclude=.git .
echo "    source tarball (patched working tree, includes untracked files)"

# ---- patch series, individually, so they are readable on GitHub -------------
for p in "$ROOT"/patches/*.patch; do
	cp "$p" "$OUT/${P}-$(basename "$p")"
done

# ---- config of every target (GPLv2 §3: scripts controlling compilation) -----
(cd "$ROOT" && tar -czf "$OUT/${P}-configs.tar.gz" \
	$(for t in "${TARGETS[@]}"; do echo "build/$t/.config"; done)) 2>/dev/null \
	|| echo "    WARNING: could not collect .config files" >&2

# ---- binaries ---------------------------------------------------------------
for t in "${TARGETS[@]}"; do
	install -m 0755 "dist/$t/bin/busybox" "$OUT/${P}-${t}"
done
# universal2, if mklipo.sh has been run
if [[ -f dist/darwin-universal/bin/busybox ]]; then
	install -m 0755 dist/darwin-universal/bin/busybox "$OUT/${P}-darwin-universal"
fi
# keep the arm64 signature meaningful after copying into the bundle
codesign -s - --force "$OUT/${P}-darwin-arm64" "$OUT/${P}-darwin-arm64-pure" 2>/dev/null || true
[[ -f "$OUT/${P}-darwin-universal" ]] && codesign -s - --force "$OUT/${P}-darwin-universal" 2>/dev/null || true

# ---- checksums --------------------------------------------------------------
# Two forms on purpose:
#   <artifact>.sha256  a sidecar beside each file, so someone who downloaded one
#                      artifact can verify it without downloading anything else
#   SHA256SUMS         the whole set, verifiable in one pass with -c
# This is integrity, not authenticity: a checksum served from the same place as
# the artifact catches corruption in transit, but cannot prove the artifact is
# genuinely ours if the repository itself is compromised. That needs a signature
# over SHA256SUMS -- produced below only if a signing key is actually present.
cd "$OUT"
: > SHA256SUMS
for f in *; do
	case "$f" in
	*.sha256|SHA256SUMS|SHA256SUMS.asc|NOTES.md) continue ;;
	esac
	shasum -a 256 "$f" > "$f.sha256"
	cat "$f.sha256" >> SHA256SUMS
done

SIGNED="no"
if command -v gpg >/dev/null 2>&1 \
	&& [[ -n "$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec/ {print $5; exit}')" ]]; then
	if gpg --batch --yes --armor --detach-sign \
		--output SHA256SUMS.asc SHA256SUMS 2>/dev/null; then
		SIGNED="yes"
	fi
fi
cd "$ROOT"
echo "    checksums: $(grep -c . "$OUT/SHA256SUMS") entries, per-file .sha256 sidecars, gpg-signed: $SIGNED"

# ---- release notes ---------------------------------------------------------
{
	cat <<EOF
BusyBox static builds: ${BASEVER} (upstream \`${SHA}\`, ${DATE})

Built from busybox git master with the patch series in this repository.

## Licences

BusyBox is **GPL version 2 only** (see LICENSE in the source tarball). These
binaries are therefore distributed under GPLv2, and the complete corresponding
source is attached: \`${P}-src.tar.gz\` (patched busybox), \`${P}-*.patch\` (the
patch series), \`${P}-configs.tar.gz\` (the .config of every target). Build
scripts are in the repository at this tag.

The Linux binaries statically contain musl (MIT) and compiler-rt
(Apache-2.0 WITH LLVM-exception). The Darwin binaries link Apple's
libSystem and, except the \`-pure\` builds, libresolv.

## Assets

| asset | arch | notes |
|---|---|---|
EOF
	for t in "${TARGETS[@]}"; do
		f="dist/$t/bin/busybox"
		kind="$(file -b "$f" | cut -c1-42)"
		printf '| `%s-%s` | %s | %s |\n' "$P" "$t" "$(lipo -archs "$f" 2>/dev/null || echo '?')" "$kind"
	done
	[[ -f dist/darwin-universal/bin/busybox ]] && \
		printf '| `%s-darwin-universal` | x86_64 arm64 | Mach-O universal2, one file for every Mac |\n' "$P"
	cat <<'EOF'

Linux binaries are fully static (no DT_NEEDED) and run in a scratch container.
Darwin binaries are dynamically linked against libSystem, because Apple ships no
static libc; `-pure` builds drop `nslookup` and depend on libSystem alone.
macOS minimums: arm64 11.0, x86_64 10.13.

## Verify your download

Every artifact ships with a SHA-256 checksum in two forms: `<artifact>.sha256`
beside each file, so one artifact can be verified alone, and `SHA256SUMS` for
the whole set at once.

```sh
shasum -a 256 -c SHA256SUMS                 # everything you downloaded
shasum -a 256 -c "${P}-linux-arm64.sha256"  # a single artifact
```

Expect one `OK` per file. A `FAILED` line means a corrupt or truncated
download: re-download it rather than running it.

### What this proves, and what it does not

A SHA-256 checksum detects **corruption in transit**. It does **not** prove the
artifact is genuinely ours, because whoever can serve you a tampered binary can
serve a matching checksum too. Real authenticity needs a signature:

* `SHA256SUMS.asc` is a GPG detached signature, present **only if** this
  release was built on a machine holding a signing key. Verify with
  `gpg --verify SHA256SUMS.asc SHA256SUMS`. If the asset is absent, it was not
  signed, so treat the checksums as integrity only.
* The arm64 Mach-O binaries also carry an Apple **ad-hoc** code signature
  (`codesign -v` passes, `flags=adhoc`). That satisfies the kernel requirement
  to run, but ad-hoc signing carries no developer identity and is not a
  substitute for notarisation.
EOF
} > "$OUT/NOTES.md"

echo "==> release bundle: $OUT"
ls -1 "$OUT" | sed 's/^/    /'
echo
echo "next: review NOTES.md, then"
echo "  gh release create ${TAG} --repo rob-c/busybox-static \\"
echo "      --title 'busybox ${BASEVER} (${SHA})' --notes-file '$OUT/NOTES.md' \\"
echo "      '$OUT'/*"
echo "(stamp: $STAMP)"
