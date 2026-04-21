# syntax=docker/dockerfile:1.7
#
# couchdb-fractalsql Factory build — zero-dependency posture.
#
# LuaJIT is compiled from source as a PIC static archive and folded
# into the fractalsql-couch binary. cJSON is pinned to a tag and
# compiled inline alongside main.c. The resulting executable depends
# on glibc only — no libluajit-5.1.so, no libcjson.so.
#
# Build artifact (collected in the final `export` stage, emitted to
# the host via `docker buildx --output type=local,dest=...`):
#   /fractalsql-couch
#
# Usage:
#   DOCKER_BUILDKIT=1 docker buildx build \
#     --platform linux/amd64 \
#     --target export \
#     --output type=local,dest=./dist/amd64 \
#     -f docker/Dockerfile .
#
# build.sh drives this for amd64 and arm64 in turn.
#
# --------------------------------------------------------------------
# Important build-system notes:
#
#  * The distro libluajit-5.1-dev ships a non-PIC .a, which fails to
#    link into most downstream binaries on amd64/arm64. We build
#    LuaJIT 2.1 ourselves with -fPIC + BUILDMODE=static and stage it
#    into /opt/luajit. This mirrors postgresql-fractalsql's factory.
#
#  * cJSON is tiny (two files, no deps) so we git-clone at a pinned
#    tag and compile cJSON.c directly into the final binary. No
#    separate .a — fewer moving parts than a cjson-static stage.
#
#  * Post-link assertions (ldd / nm / size) run inside the build
#    stage so the build fails fast if a dynamic luajit/cjson/stdc++
#    dependency ever sneaks back in.
#
#  * Base image is debian:bullseye-slim (glibc 2.31), not bookworm-slim
#    (glibc 2.36). The binary's ELF symbol requirements follow the
#    build environment's glibc, so bookworm-built binaries refuse to
#    run on RHEL 9 / Rocky 9 / AlmaLinux 9 (all glibc 2.34). Bullseye
#    buys us RHEL 9 + Debian 11+ + Ubuntu 20.04+ + Fedora 35+ without
#    a functional tradeoff — LuaJIT 2.1 builds fine on both.

ARG LUAJIT_GIT_URL=https://github.com/LuaJIT/LuaJIT.git
ARG LUAJIT_GIT_REF=v2.1

ARG CJSON_GIT_URL=https://github.com/DaveGamble/cJSON.git
ARG CJSON_GIT_REF=v1.7.18

# EXT_CFLAGS / EXT_LDFLAGS — appended onto the gcc command line inside
# the build-couch stage. Same hygiene set the Postgres factory uses,
# minus the -D_GLIBCXX flags (we have no C++).
ARG EXT_CFLAGS="-ffunction-sections -fdata-sections"
ARG EXT_LDFLAGS="-static-libgcc -Wl,--gc-sections -Wl,--strip-all -Wl,--exclude-libs,ALL"

# Ceiling on the resulting binary. LuaJIT's static archive is ~1MB;
# our C is small; 3MB gives headroom without masking bloat regressions.
ARG SIZE_CEILING_BYTES=3145728

# --------------------------------------------------------------------
# Stage: PIC-built LuaJIT static archive
# --------------------------------------------------------------------
FROM debian:bullseye-slim AS luajit-static
ARG LUAJIT_GIT_URL
ARG LUAJIT_GIT_REF
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential ca-certificates git \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth=1 --branch "${LUAJIT_GIT_REF}" \
        "${LUAJIT_GIT_URL}" /src/luajit
WORKDIR /src/luajit
RUN make BUILDMODE=static XCFLAGS="-fPIC" PREFIX=/opt/luajit -j"$(nproc)" \
 && make install BUILDMODE=static PREFIX=/opt/luajit \
 && test -f /opt/luajit/lib/libluajit-5.1.a \
 && ! test -f /opt/luajit/lib/libluajit-5.1.so

# --------------------------------------------------------------------
# Stage: couch binary builder
# --------------------------------------------------------------------
FROM debian:bullseye-slim AS build-couch
ARG CJSON_GIT_URL
ARG CJSON_GIT_REF
ARG EXT_CFLAGS
ARG EXT_LDFLAGS
ARG SIZE_CEILING_BYTES

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        ca-certificates \
        file \
        git \
 && rm -rf /var/lib/apt/lists/*

COPY --from=luajit-static /opt/luajit /opt/luajit

RUN git clone --depth=1 --branch "${CJSON_GIT_REF}" \
        "${CJSON_GIT_URL}" /src/cjson

WORKDIR /build
COPY src/     /build/src/
COPY include/ /build/include/
COPY docker/assert_bin.sh /build/docker/assert_bin.sh

# Single gcc invocation: src/main.c + cJSON.c + static libluajit-5.1.a
# -> /fractalsql-couch. The cJSON include path points at /src/cjson so
# the system <cjson/cJSON.h> expected by main.c resolves to the vendored
# source copy via a shim dir.
RUN mkdir -p /src/cjson-shim/cjson \
 && ln -s /src/cjson/cJSON.h /src/cjson-shim/cjson/cJSON.h \
 && gcc -std=c99 -O2 -Wall -Wextra -Wno-unused-parameter \
        -I/opt/luajit/include/luajit-2.1 \
        -Iinclude -Isrc \
        -I/src/cjson-shim \
        -I/src/cjson \
        ${EXT_CFLAGS} \
        -o /fractalsql-couch \
        src/main.c /src/cjson/cJSON.c \
        /opt/luajit/lib/libluajit-5.1.a \
        -lm -ldl \
        ${EXT_LDFLAGS} \
 && sh /build/docker/assert_bin.sh /fractalsql-couch "${SIZE_CEILING_BYTES}"

# --------------------------------------------------------------------
# Export stage — scratch, so `buildx --output=local` drops just the
# binary onto the host.
# --------------------------------------------------------------------
FROM scratch AS export
COPY --from=build-couch /fractalsql-couch /fractalsql-couch
