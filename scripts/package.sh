#!/usr/bin/env bash
#
# scripts/package.sh — produce source tarball and SHA256 checksums
# for everything under dist/.
#
# Runs after build.sh + build_deb.sh + build_rpm.sh have populated
# dist/{amd64,arm64}/ with binaries and packages. Intended for both
# local release rehearsal and GitHub Actions.
#
# Usage: scripts/package.sh
#
# Outputs:
#   dist/couchdb-fractalsql-<version>-src.tar.gz
#   dist/SHA256SUMS

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO}"

VERSION="1.0.0"
NAME="couchdb-fractalsql"
SRC_TARBALL="dist/${NAME}-${VERSION}-src.tar.gz"

mkdir -p dist

# ------------------------------------------------------------------ #
# Source tarball                                                     #
# ------------------------------------------------------------------ #
#
# Exclude build outputs and any VCS metadata. The tarball's top-level
# directory is NAME-VERSION/ so downstream spec files can use %setup.
echo "--- source tarball ---"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${STAGE}/${NAME}-${VERSION}"
tar -cf - \
    --exclude='./.git' \
    --exclude='./dist' \
    --exclude='./debian' \
    --exclude='./fractalsql-couch' \
    --exclude='./.github/workflows/*.cache' \
    . | tar -xf - -C "${STAGE}/${NAME}-${VERSION}"

tar -czf "${SRC_TARBALL}" -C "${STAGE}" "${NAME}-${VERSION}"
echo "wrote ${SRC_TARBALL} ($(stat -c '%s' "${SRC_TARBALL}") bytes)"

# ------------------------------------------------------------------ #
# SHA256SUMS                                                         #
# ------------------------------------------------------------------ #
#
# One line per artifact, relative paths under dist/. Matches the
# format expected by `sha256sum -c`.
echo
echo "--- SHA256SUMS ---"
( cd dist && \
    find . -type f \
        \( -name '*.tar.gz' -o -name '*.deb' -o -name '*.rpm' \
           -o -name '*.msi' -o -name '*.pkg' -o -name '*.zip' \
           -o -name 'fractalsql-couch' \) \
        -print0 \
    | sort -z \
    | xargs -0 sha256sum \
) > dist/SHA256SUMS

cat dist/SHA256SUMS

echo
echo "Artifacts ready in dist/:"
find dist -maxdepth 3 -type f | sort
