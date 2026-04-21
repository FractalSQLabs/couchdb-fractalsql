#!/bin/sh
# docker/assert_bin.sh — zero-dependency posture check for
# fractalsql-couch. Adapted from postgresql-fractalsql's assert_so.sh;
# the differences are: we assert on an ET_EXEC/ET_DYN executable rather
# than a .so, and the cxx11 ABI check is kept defensively even though
# the couch TU has no C++.
#
# Usage: assert_bin.sh <path/to/fractalsql-couch> <size_ceiling_bytes>
#
# Fails the build if:
#   * ldd reports any dynamic library outside the glibc shortlist
#   * nm reports __cxx11::basic_string symbols (should never happen;
#     guards against a future C++ dep leaking in)
#   * the binary exceeds the size ceiling
#
# Run inside the build-couch stage so problems are caught before the
# binary is emitted to the export stage.

set -eu

BIN="${1:?usage: assert_bin.sh <bin> <ceiling>}"
CEILING="${2:?usage: assert_bin.sh <bin> <ceiling>}"

echo "=== assert_bin.sh ${BIN} (ceiling ${CEILING} bytes) ==="

echo "--- file ---"
file "${BIN}"

echo "--- ldd ---"
ldd "${BIN}" || true

# Assertion 1: no dynamic libluajit / libcjson / libstdc++ dependency.
if ldd "${BIN}" | grep -E 'libluajit|libcjson|libstdc\+\+' >/dev/null; then
    echo "FAIL: ${BIN} links dynamic libluajit/libcjson/libstdc++" >&2
    exit 1
fi

# Assertion 2: every library listed by ldd is on the glibc shortlist.
# Allowed SONAME prefixes (bookworm glibc 2.36+):
#   linux-vdso.so.1       (kernel-provided, no file)
#   libc.so.6
#   libm.so.6
#   libdl.so.2            (merged into libc on glibc 2.34+, may still appear)
#   libpthread.so.0       (merged into libc on glibc 2.34+, may still appear)
#   /lib*/ld-linux-*.so.* (dynamic loader)
BAD=$(ldd "${BIN}" \
        | awk '{print $1}' \
        | grep -vE '^(linux-vdso\.so\.1|libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|/.*/ld-linux.*\.so\.[0-9]+)$' \
        | grep -v '^$' || true)
if [ -n "${BAD}" ]; then
    echo "FAIL: ${BIN} has disallowed dynamic deps:" >&2
    echo "${BAD}" >&2
    exit 1
fi

# Assertion 3: no __cxx11::basic_string symbols (ABI hygiene).
echo "--- nm -D -C | grep __cxx11::basic_string ---"
if nm -D -C "${BIN}" 2>/dev/null | grep -F '__cxx11::basic_string' >/dev/null; then
    echo "FAIL: ${BIN} exposes __cxx11::basic_string symbols" >&2
    nm -D -C "${BIN}" | grep -F '__cxx11::basic_string' >&2 || true
    exit 1
fi

# Assertion 4: size ceiling.
SZ=$(stat -c '%s' "${BIN}")
echo "size: ${SZ} bytes (ceiling ${CEILING})"
if [ "${SZ}" -gt "${CEILING}" ]; then
    echo "FAIL: ${BIN} exceeds size ceiling ${CEILING}" >&2
    exit 1
fi

echo "OK: ${BIN}"
