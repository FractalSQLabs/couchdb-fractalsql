# Makefile
# FractalSQL v1.0 — CouchDB External Query Server.
#
# Vertical slice: builds the fractalsql-couch binary and runs the
# heartbeat tests. Windows MSI and macOS universal packaging are
# intentionally out of scope here.
#
# Deps (Debian/Ubuntu):
#   sudo apt install libluajit-5.1-dev libcjson-dev
#
# The sfs_core bytecode header is vendored under include/ so this
# repo stands alone. For release artifacts that need zero runtime
# deps (static-linked LuaJIT + cJSON), run `make release` which
# shells out to ./build.sh (docker buildx).

CC       ?= gcc
CSTD     ?= -std=c99
CWARN    ?= -Wall -Wextra -Wno-unused-parameter
COPT     ?= -O2

LUAJIT_CFLAGS := $(shell pkg-config --cflags luajit)
LUAJIT_LIBS   := $(shell pkg-config --libs luajit)
CJSON_LIBS    := -lcjson

SFS_INCLUDE := -Iinclude

BIN := fractalsql-couch
SRC := src/main.c
HDR := src/fractal_bridge.h

CFLAGS_ALL = $(CSTD) $(CWARN) $(COPT) $(LUAJIT_CFLAGS) $(SFS_INCLUDE) -Isrc $(CFLAGS)
LDLIBS_ALL = $(LUAJIT_LIBS) $(CJSON_LIBS) $(LDLIBS)

.PHONY: all test clean check-deps release release-amd64 release-arm64

all: $(BIN)

$(BIN): $(SRC) $(HDR)
	$(CC) $(CFLAGS_ALL) -o $@ $(SRC) $(LDLIBS_ALL)

check-deps:
	@pkg-config --exists luajit || { \
		echo "ERROR: luajit pkg-config not found. Install libluajit-5.1-dev."; \
		exit 1; }
	@printf '#include <cjson/cJSON.h>\nint main(void){return 0;}\n' \
		| $(CC) -x c - -lcjson -o /dev/null 2>/dev/null \
		|| { echo "ERROR: cJSON not found. Install libcjson-dev."; exit 1; }
	@test -f include/sfs_core_bc.h \
		|| { echo "ERROR: include/sfs_core_bc.h missing (should be vendored in-tree)."; exit 1; }
	@echo "deps OK"

test: $(BIN)
	@./tests/heartbeat.sh

clean:
	rm -f $(BIN)
	rm -rf dist/

# Release builds shell out to build.sh, which drives docker buildx to
# produce static, zero-runtime-dep binaries for Linux. No host-side
# LuaJIT or cJSON install is required — the Dockerfile builds LuaJIT
# from source as a PIC static archive and folds it into the binary.
release: release-amd64 release-arm64

release-amd64:
	./build.sh amd64

release-arm64:
	./build.sh arm64
