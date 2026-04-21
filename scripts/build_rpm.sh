#!/usr/bin/env bash
#
# scripts/build_rpm.sh — wrap the static binary in an .rpm.
#
# Runs rpmbuild inside a rockylinux:9 container so the resulting RPM
# has the right macros and dependency resolution for RHEL/CentOS/
# Fedora targets. Native rpmbuild on Debian works but produces subtly
# different metadata; the container avoids that footgun.
#
# Usage:
#   scripts/build_rpm.sh [amd64|arm64]   # default: amd64
#
# Requires: docker (or podman with docker shim). Pass USE_PODMAN=1 to
# use podman directly if preferred.

set -euo pipefail

ARCH="${1:-amd64}"
case "${ARCH}" in
    amd64) RPM_ARCH=x86_64 ;;
    arm64) RPM_ARCH=aarch64 ;;
    *) echo "unknown arch '${ARCH}' — expected amd64 or arm64" >&2; exit 2 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${REPO}/dist/${ARCH}/fractalsql-couch"

if [[ ! -f "${BIN}" ]]; then
    echo "ERROR: ${BIN} missing. Run './build.sh ${ARCH}' first." >&2
    exit 1
fi

VERSION="1.0.0"
NAME="fractalsql-couch"
DOCKER="${USE_PODMAN:-}"; [[ "${DOCKER}" == "1" ]] && DOCKER=podman || DOCKER=docker

mkdir -p "${REPO}/dist/${ARCH}"

# Stage a source tarball for %setup. rpmbuild expects
# NAME-VERSION/contents inside; easiest is to re-tar the repo with
# that prefix.
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${STAGE}/${NAME}-${VERSION}"
tar -cf - \
    -C "${REPO}" \
    --exclude='./.git' \
    --exclude='./dist' \
    --exclude='./debian' \
    --exclude='./fractalsql-couch' \
    . | tar -xf - -C "${STAGE}/${NAME}-${VERSION}"

# Re-add just the arch-specific binary so %build finds it.
mkdir -p "${STAGE}/${NAME}-${VERSION}/dist/${ARCH}"
cp "${BIN}" "${STAGE}/${NAME}-${VERSION}/dist/${ARCH}/fractalsql-couch"

tar -czf "${STAGE}/${NAME}-${VERSION}.tar.gz" -C "${STAGE}" "${NAME}-${VERSION}"

echo "--- staged tarball ---"
ls -l "${STAGE}/${NAME}-${VERSION}.tar.gz"

PLATFORM="linux/${ARCH}"

${DOCKER} run --rm \
    --platform "${PLATFORM}" \
    -v "${STAGE}:/work" \
    -v "${REPO}/dist/${ARCH}:/out" \
    rockylinux:9 \
    bash -c "
        set -euo pipefail
        dnf -y install rpm-build rpmdevtools >/dev/null
        rpmdev-setuptree
        cp /work/${NAME}-${VERSION}.tar.gz /root/rpmbuild/SOURCES/
        cp /work/${NAME}-${VERSION}/packaging/rpm/${NAME}.spec /root/rpmbuild/SPECS/
        rpmbuild --define 'rpm_arch ${ARCH}' -bb /root/rpmbuild/SPECS/${NAME}.spec
        cp /root/rpmbuild/RPMS/${RPM_ARCH}/*.rpm /out/
    "

echo
echo "Built .rpm for ${ARCH}:"
ls -l "${REPO}/dist/${ARCH}/"*.rpm

# Foundry-convention rename. Siblings produce `<repo>-<arch>.rpm`
# via fpm; rpmbuild emits `<pkg>-<ver>-<rel>.<dist>.<rpm_arch>.rpm`.
# Copy to the foundry-shaped name in dist/packages/.
mkdir -p "${REPO}/dist/packages"
SRC_RPM="$(ls "${REPO}/dist/${ARCH}/"fractalsql-couch-*."${RPM_ARCH}".rpm | head -1)"
CANONICAL="${REPO}/dist/packages/couchdb-fractalsql-${ARCH}.rpm"
cp -v "${SRC_RPM}" "${CANONICAL}"
