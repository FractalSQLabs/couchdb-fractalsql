#!/usr/bin/env bash
#
# scripts/build_deb.sh — wrap the static binary in a .deb.
#
# Assumes the binary has already been produced by ../build.sh and sits
# at dist/<arch>/fractalsql-couch. Copies packaging/debian/ into a
# scratch ./debian tree and invokes dpkg-buildpackage there.
#
# Usage:
#   scripts/build_deb.sh [amd64|arm64]   # default: host arch
#
# Requires: dpkg-dev, debhelper (apt install dpkg-dev debhelper)

set -euo pipefail

ARCH="${1:-$(dpkg-architecture -qDEB_HOST_ARCH 2>/dev/null || echo amd64)}"
case "${ARCH}" in
    amd64|arm64) ;;
    *) echo "unknown arch '${ARCH}' — expected amd64 or arm64" >&2; exit 2 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${REPO}/dist/${ARCH}/fractalsql-couch"

if [[ ! -f "${BIN}" ]]; then
    echo "ERROR: ${BIN} missing. Run './build.sh ${ARCH}' first." >&2
    exit 1
fi

cd "${REPO}"
rm -rf debian
cp -r packaging/debian debian

# dpkg-buildpackage runs in the repo root. -a<arch> sets the target
# architecture; -us/-uc skip signing (CI signs artifacts separately
# via gpg after the fact).
# -d skips the Build-Depends check. The binary is pre-built by
# build.sh (via docker buildx) and staged into dist/<arch>/ before we
# get here, so nothing in debian/rules actually compiles source —
# debhelper's override steps just copy files. dpkg-checkbuilddeps
# still resolves debhelper-compat's transitive build-essential:native
# dep strictly even when the runner has build-essential installed,
# which produces a spurious failure. Since there is no build step to
# miss, -d is the right posture here.
DEB_HOST_ARCH="${ARCH}" dpkg-buildpackage -us -uc -b -d -a"${ARCH}"

# dpkg-buildpackage drops artifacts in the parent dir.
mkdir -p "dist/${ARCH}"
mv -v ../fractalsql-couch_*_"${ARCH}".deb "dist/${ARCH}/" 2>/dev/null || true
mv -v ../fractalsql-couch_*_"${ARCH}".buildinfo "dist/${ARCH}/" 2>/dev/null || true
mv -v ../fractalsql-couch_*_"${ARCH}".changes "dist/${ARCH}/" 2>/dev/null || true

rm -rf debian

echo
echo "Built .deb for ${ARCH}:"
ls -l "dist/${ARCH}/"*.deb

# Foundry-convention rename. Siblings (sqlite-fractalsql,
# postgresql-fractalsql) use fpm, which lets them produce
# `<repo>-<arch>.deb` directly. dpkg-buildpackage emits the
# dpkg-native name `<pkg>_<ver>-<iter>_<arch>.deb`. Copy to the
# foundry-shaped name in dist/packages/ so release artifacts are
# consistent across the foundry.
mkdir -p dist/packages
SRC_DEB="$(ls "dist/${ARCH}/"fractalsql-couch_*_"${ARCH}".deb | head -1)"
CANONICAL="dist/packages/couchdb-fractalsql-${ARCH}.deb"
cp -v "${SRC_DEB}" "${CANONICAL}"
