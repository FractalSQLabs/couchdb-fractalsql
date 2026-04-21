#!/usr/bin/env bash
#
# scripts/macos/build-pkg.sh — produce the universal Mach-O binary
# plus a macOS installer .pkg.
#
# Inputs (expected to exist):
#   dist/osx_amd64/fractalsql-couch   (Intel slice,      via build.sh)
#   dist/osx_arm64/fractalsql-couch   (Apple Silicon,    via build.sh)
#
# Outputs:
#   dist/osx_universal/fractalsql-couch
#   dist/osx_universal/FractalSQL-CouchDB-1.0.0-universal.pkg
#
# Usage: scripts/macos/build-pkg.sh
#
# Signing and notarization are gated on secrets being present in the
# environment. When absent the script still produces a fully-working
# .pkg; Gatekeeper will warn on first launch but installs succeed for
# users who right-click → Open or run `spctl --master-disable`.
#
# Secret variables honored (all optional):
#   APPLE_DEVELOPER_ID_APPLICATION   "Developer ID Application: ..."
#   APPLE_DEVELOPER_ID_INSTALLER     "Developer ID Installer: ..."
#   APPLE_KEYCHAIN_PROFILE           notarytool keychain profile name
#
# A caller-supplied step is responsible for importing the certs into
# the runner keychain before invoking this script (see release.yml).

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO}"

VERSION="1.0.0"
PKG_IDENTIFIER="io.fractalsqlabs.couchdb-fractalsql"

AMD64_BIN="dist/osx_amd64/fractalsql-couch"
ARM64_BIN="dist/osx_arm64/fractalsql-couch"

for f in "${AMD64_BIN}" "${ARM64_BIN}"; do
    if [[ ! -f "${f}" ]]; then
        echo "ERROR: ${f} missing. Build both slices first:" >&2
        echo "  scripts/macos/build.sh amd64   (cross-compile on macos-14)" >&2
        echo "  scripts/macos/build.sh arm64   (native on macos-14)" >&2
        exit 1
    fi
done

OUT_DIR="dist/osx_universal"
mkdir -p "${OUT_DIR}"

# ------------------------------------------------------------------ #
# lipo — combine slices                                              #
# ------------------------------------------------------------------ #
UNIV_BIN="${OUT_DIR}/fractalsql-couch"
lipo -create -output "${UNIV_BIN}" "${AMD64_BIN}" "${ARM64_BIN}"
file "${UNIV_BIN}"

echo "==> universal binary at ${UNIV_BIN}"

# ------------------------------------------------------------------ #
# Optional codesign (Developer ID Application)                       #
# ------------------------------------------------------------------ #
if [[ -n "${APPLE_DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "==> codesigning binary as '${APPLE_DEVELOPER_ID_APPLICATION}'"
    codesign --force --options runtime --timestamp \
        --sign "${APPLE_DEVELOPER_ID_APPLICATION}" \
        "${UNIV_BIN}"
    codesign --verify --verbose "${UNIV_BIN}"
else
    echo "==> APPLE_DEVELOPER_ID_APPLICATION not set — skipping codesign"
fi

# ------------------------------------------------------------------ #
# pkgbuild — stage files into a payload, wrap as a component .pkg    #
# ------------------------------------------------------------------ #
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

# Install layout:
#   /usr/local/bin/fractalsql-couch
#   /usr/local/share/doc/fractalsql-couch/{README_COUCH.txt, LICENSE, THIRD-PARTY-NOTICES.md}
install -d "${STAGE}/usr/local/bin"
install -m 0755 "${UNIV_BIN}" "${STAGE}/usr/local/bin/fractalsql-couch"

install -d "${STAGE}/usr/local/share/doc/fractalsql-couch"
install -m 0644 packaging/README_COUCH.txt  "${STAGE}/usr/local/share/doc/fractalsql-couch/"
install -m 0644 LICENSE                     "${STAGE}/usr/local/share/doc/fractalsql-couch/"
install -m 0644 THIRD-PARTY-NOTICES.md      "${STAGE}/usr/local/share/doc/fractalsql-couch/"

COMPONENT_PKG="${OUT_DIR}/fractalsql-couch-component.pkg"
PRODUCT_PKG="${OUT_DIR}/FractalSQL-CouchDB-${VERSION}-universal.pkg"

PKGBUILD_ARGS=(
    --root "${STAGE}"
    --identifier "${PKG_IDENTIFIER}"
    --version "${VERSION}"
    --install-location "/"
    "${COMPONENT_PKG}"
)
if [[ -n "${APPLE_DEVELOPER_ID_INSTALLER:-}" ]]; then
    PKGBUILD_ARGS=(--sign "${APPLE_DEVELOPER_ID_INSTALLER}" "${PKGBUILD_ARGS[@]}")
fi
pkgbuild "${PKGBUILD_ARGS[@]}"

# productbuild wraps the component so Installer.app shows a friendly
# title. A minimal distribution plist lives inline.
DIST_XML="${STAGE}/distribution.xml"
cat > "${DIST_XML}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>FractalSQL for Apache CouchDB</title>
    <organization>io.fractalsqlabs</organization>
    <pkg-ref id="${PKG_IDENTIFIER}"/>
    <options customize="never" require-scripts="false"/>
    <choices-outline>
        <line choice="default">
            <line choice="${PKG_IDENTIFIER}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${PKG_IDENTIFIER}" visible="false">
        <pkg-ref id="${PKG_IDENTIFIER}"/>
    </choice>
    <pkg-ref id="${PKG_IDENTIFIER}" version="${VERSION}" onConclusion="none">fractalsql-couch-component.pkg</pkg-ref>
</installer-gui-script>
EOF

PRODUCTBUILD_ARGS=(
    --distribution "${DIST_XML}"
    --package-path "${OUT_DIR}"
    "${PRODUCT_PKG}"
)
if [[ -n "${APPLE_DEVELOPER_ID_INSTALLER:-}" ]]; then
    PRODUCTBUILD_ARGS=(--sign "${APPLE_DEVELOPER_ID_INSTALLER}" "${PRODUCTBUILD_ARGS[@]}")
fi
productbuild "${PRODUCTBUILD_ARGS[@]}"

rm -f "${COMPONENT_PKG}"

echo
echo "==> produced ${PRODUCT_PKG}"
ls -l "${PRODUCT_PKG}"

# ------------------------------------------------------------------ #
# Optional notarization                                              #
# ------------------------------------------------------------------ #
if [[ -n "${APPLE_KEYCHAIN_PROFILE:-}" ]]; then
    echo "==> notarizing via notarytool profile '${APPLE_KEYCHAIN_PROFILE}'"
    xcrun notarytool submit "${PRODUCT_PKG}" \
        --keychain-profile "${APPLE_KEYCHAIN_PROFILE}" \
        --wait
    xcrun stapler staple "${PRODUCT_PKG}"
    xcrun stapler validate "${PRODUCT_PKG}"
else
    echo "==> APPLE_KEYCHAIN_PROFILE not set — skipping notarization"
fi
