#!/bin/bash
#
# couchdb-fractalsql multi-arch static build.
#
# Drives docker/Dockerfile to produce one fractalsql-couch binary per
# target architecture. Output layout:
#   dist/amd64/fractalsql-couch
#   dist/arm64/fractalsql-couch
#
# Usage:
#   ./build.sh [amd64|arm64]        # default: amd64
#
# Cross-arch builds need QEMU + binfmt_misc. In CI this is handled by
# docker/setup-qemu-action; locally:
#   docker run --privileged --rm tonistiigi/binfmt --install all

set -euo pipefail

ARCH="${1:-amd64}"
case "${ARCH}" in
    amd64|arm64) ;;
    *)
        echo "unknown arch '${ARCH}' — expected amd64 or arm64" >&2
        exit 2
        ;;
esac

DIST_DIR="${DIST_DIR:-./dist}"
DOCKERFILE="${DOCKERFILE:-docker/Dockerfile}"
PLATFORM="linux/${ARCH}"
OUT_DIR="${DIST_DIR}/${ARCH}"

mkdir -p "${OUT_DIR}"

echo "------------------------------------------"
echo "Building couchdb-fractalsql for ${PLATFORM}"
echo "  -> ${OUT_DIR}/fractalsql-couch"
echo "------------------------------------------"

DOCKER_BUILDKIT=1 docker buildx build \
    --platform "${PLATFORM}" \
    --target export \
    --output "type=local,dest=${OUT_DIR}" \
    -f "${DOCKERFILE}" \
    .

echo
echo "Built artifact for ${ARCH}:"
ls -l "${OUT_DIR}"/fractalsql-couch
