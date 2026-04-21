/* src/fractal_bridge.h
 * FractalSQL v1.0 — CouchDB External Query Server bridge.
 *
 * One LuaJIT state per process. Map functions registered via CouchDB's
 * `add_fun` are compiled once and pinned in the Lua registry. `map_doc`
 * invokes each registered function with the decoded document; emits are
 * collected into a per-function cJSON array that is returned to the
 * caller as one batched line.
 *
 * The sfs_core stripped bytecode (shipped in the postgresql-fractalsql
 * sibling at include/sfs_core_bc.h) is loaded on init and its module
 * table pinned in the registry for O(1) access.
 */

#ifndef FRACTALSQL_COUCH_BRIDGE_H
#define FRACTALSQL_COUCH_BRIDGE_H

#include <stddef.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <cjson/cJSON.h>

#define FRACTALSQL_EDITION "Community"
#define FRACTALSQL_VERSION "1.0.0"

typedef struct fb_state {
    lua_State *L;
    int        sfs_module_ref;
    int       *fun_refs;
    size_t     fun_count;
    size_t     fun_capacity;
    cJSON     *emit_buf;   /* borrowed; owned by caller during map_doc */
} fb_state_t;

/* Returns 0 on success; on failure writes a malloc'd message to *err
 * (caller frees) and leaves state unusable. */
int  fb_init(fb_state_t *s, char **err);

/* Tears down the Lua state and frees all registry refs. Safe on a
 * zero-initialized or already-freed state. */
void fb_free(fb_state_t *s);

/* Drops every registered map function. The Lua state and sfs_core
 * module stay loaded — only the user-supplied functions are cleared. */
void fb_reset(fb_state_t *s);

/* Compiles `src` (expected to evaluate to a function value) and pins
 * the result in the registry. Returns 0 on success; on compile/eval
 * failure writes a malloc'd message to *err. */
int  fb_add_fun(fb_state_t *s, const char *src, char **err);

/* Runs every registered function against `doc`. Returns a cJSON array
 * of length fun_count; each element is itself an array of [key,value]
 * emits. Caller owns and frees the returned cJSON. On hard failure
 * returns NULL and writes *err. A single failing map function yields
 * an empty sub-array for that slot rather than a hard failure. */
cJSON *fb_map_doc(fb_state_t *s, const cJSON *doc, char **err);

#endif
