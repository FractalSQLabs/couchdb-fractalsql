#!/usr/bin/env bash
#
# scripts/macos/build.sh — build the fractalsql-couch binary for one
# macOS architecture. Designed to run on macos-14 (Apple Silicon)
# runners; the amd64 slice is produced via clang's `-arch x86_64`
# cross-compile and LuaJIT's HOST_CC/TARGET_* build split.
#
# Why not run amd64 natively on macos-13?
#   GitHub's Intel macOS runner pool (`macos-13`) has become severely
#   capacity-constrained since the default macos runner moved to
#   Apple Silicon. Jobs routinely queue for tens of minutes or time
#   out. Apple Silicon runners have abundant capacity and Apple's
#   clang toolchain can emit both architectures, so we do both builds
#   on macos-14.
#
# MACOSX_DEPLOYMENT_TARGET=11.0 is required by LuaJIT's Makefile on
# Darwin. 11.0 is the oldest target supporting both slices.
#
# Usage:
#   scripts/macos/build.sh              # detect host arch
#   scripts/macos/build.sh amd64        # Intel slice (cross on arm64)
#   scripts/macos/build.sh arm64        # Apple Silicon slice (native)
#
# Output:
#   dist/osx_<arch>/fractalsql-couch    (Mach-O single-arch binary)

set -euo pipefail

HOST_ARCH="$(uname -m)"
case "${HOST_ARCH}" in
    x86_64)  HOST_TAG=amd64 ;;
    arm64)   HOST_TAG=arm64 ;;
    *) echo "unsupported macOS host arch: ${HOST_ARCH}" >&2; exit 2 ;;
esac

ARCH="${1:-${HOST_TAG}}"
case "${ARCH}" in
    amd64) MARCH=x86_64 ;;
    arm64) MARCH=arm64  ;;
    *) echo "unknown arch '${ARCH}' — expected amd64 or arm64" >&2; exit 2 ;;
esac

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${REPO}/dist/osx_${ARCH}"
mkdir -p "${OUT_DIR}"

echo "==> host arch       = ${HOST_TAG} (${HOST_ARCH})"
echo "==> target arch     = ${ARCH} (-arch ${MARCH})"
echo "==> macos target    = ${MACOSX_DEPLOYMENT_TARGET}"
echo "==> OUT_DIR         = ${OUT_DIR}"

# ------------------------------------------------------------------ #
# LuaJIT static archive                                              #
# ------------------------------------------------------------------ #
#
# LuaJIT's build runs in two phases:
#   1. Host phase: compile `minilua` + `buildvm` natively so they can
#      execute on the build machine and emit generated files.
#   2. Target phase: compile the runtime .o files for the target arch.
#
# When HOST_ARCH == target arch (arm64 → arm64), this collapses into
# a single native build with no TARGET_FLAGS. When cross-compiling
# (arm64 → x86_64), we hand HOST_CC an untouched clang (native arm64)
# and TARGET_FLAGS="-arch x86_64" so the final library comes out
# x86_64 while the generators still run as arm64.
LUAJIT_DIR="${LUAJIT_DIR:-/tmp/luajit-${ARCH}}"
LUAJIT_INSTALL="${LUAJIT_DIR}-install"

if [[ ! -f "${LUAJIT_INSTALL}/lib/libluajit-5.1.a" ]]; then
    echo "==> building LuaJIT static (${ARCH}) at ${LUAJIT_DIR}"
    rm -rf "${LUAJIT_DIR}" "${LUAJIT_INSTALL}"
    git clone --depth=1 --branch v2.1 \
        https://github.com/LuaJIT/LuaJIT.git "${LUAJIT_DIR}"

    if [[ "${HOST_TAG}" == "${ARCH}" ]]; then
        # Native path — LuaJIT's own defaults Just Work.
        (
            cd "${LUAJIT_DIR}"
            make BUILDMODE=static XCFLAGS="-fPIC" \
                 PREFIX="${LUAJIT_INSTALL}" \
                 -j"$(sysctl -n hw.ncpu)"
            make install BUILDMODE=static PREFIX="${LUAJIT_INSTALL}"
        )
    else
        # Cross path — host is arm64, target is x86_64 (or vice-versa
        # if we ever ran this on macos-13). HOST_CC builds the
        # generators for the host arch; TARGET_FLAGS drives the .o's
        # for the target arch. CROSS stays empty: we use the same
        # clang binary in both roles, just with different -arch flags.
        (
            cd "${LUAJIT_DIR}"
            make BUILDMODE=static \
                 HOST_CC="clang" \
                 TARGET_FLAGS="-arch ${MARCH}" \
                 TARGET_SYS=Darwin \
                 XCFLAGS="-fPIC" \
                 PREFIX="${LUAJIT_INSTALL}" \
                 -j"$(sysctl -n hw.ncpu)"
            make install BUILDMODE=static PREFIX="${LUAJIT_INSTALL}"
        )
    fi
    test -f "${LUAJIT_INSTALL}/lib/libluajit-5.1.a"
fi

# ------------------------------------------------------------------ #
# cJSON source                                                       #
# ------------------------------------------------------------------ #
CJSON_DIR="${CJSON_DIR:-/tmp/cjson}"
CJSON_REF="${CJSON_REF:-v1.7.18}"

if [[ ! -f "${CJSON_DIR}/cJSON.c" ]]; then
    echo "==> cloning cJSON at ${CJSON_REF} into ${CJSON_DIR}"
    rm -rf "${CJSON_DIR}"
    git clone --depth=1 --branch "${CJSON_REF}" \
        https://github.com/DaveGamble/cJSON.git "${CJSON_DIR}"
fi

# ------------------------------------------------------------------ #
# Compile                                                            #
# ------------------------------------------------------------------ #
SHIM_DIR="/tmp/cjson-shim"
mkdir -p "${SHIM_DIR}/cjson"
ln -sf "${CJSON_DIR}/cJSON.h" "${SHIM_DIR}/cjson/cJSON.h"

cd "${REPO}"

# -dead_strip is macOS's analogue of -Wl,--gc-sections; trims unused
# LuaJIT code paths. -pagezero_size/-image_base are x86_64-only:
# LuaJIT on Intel macOS uses 32-bit internal pointer encoding and
# needs the loader to place everything under 4GB. On arm64 LuaJIT
# uses full 64-bit addressing; these flags cause the kernel's
# Hardened Runtime to SIGKILL the process on exec.
X86_LDFLAGS=""
if [[ "${MARCH}" == "x86_64" ]]; then
    X86_LDFLAGS="-Wl,-pagezero_size,10000 -Wl,-image_base,100000000"
fi

clang -std=c99 -O2 -Wall -Wextra -Wno-unused-parameter \
    -arch "${MARCH}" \
    -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET}" \
    -I"${LUAJIT_INSTALL}/include/luajit-2.1" \
    -I"${SHIM_DIR}" -I"${CJSON_DIR}" \
    -Iinclude -Isrc \
    -o "${OUT_DIR}/fractalsql-couch" \
    src/main.c "${CJSON_DIR}/cJSON.c" \
    "${LUAJIT_INSTALL}/lib/libluajit-5.1.a" \
    -lm \
    -Wl,-dead_strip \
    ${X86_LDFLAGS}

file "${OUT_DIR}/fractalsql-couch"
ls -l "${OUT_DIR}/fractalsql-couch"

echo
echo "==> otool -L (runtime dependencies):"
otool -L "${OUT_DIR}/fractalsql-couch"

echo "==> done: ${OUT_DIR}/fractalsql-couch"
