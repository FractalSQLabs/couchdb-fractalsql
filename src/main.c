/* src/main.c
 * FractalSQL v1.0 — CouchDB External Query Server.
 *
 * Protocol
 *   CouchDB speaks JSON-over-stdio to an external query server. Each
 *   request is a single-line JSON array whose first element is a
 *   command string; each response is a single-line JSON value.
 *
 *     ["reset" [, config]]                         -> true
 *     ["add_fun", "<lua source>"]                  -> true
 *     ["map_doc", {doc}]                           -> [[[k,v],...], ...]
 *
 *   For map_doc the outer array has one entry per previously added
 *   function, in registration order. Each entry is the batch of
 *   [key,value] pairs that function's emit() calls produced for this
 *   document; zero emits produces [].
 *
 * Engine
 *   One LuaJIT state per process. The sfs_core stripped bytecode from
 *   postgresql-fractalsql/include/sfs_core_bc.h is loaded at startup
 *   and its module table pinned in the registry. Registered map
 *   functions receive the document as a Lua table and may call the
 *   global `emit(key, value)` closure, whose C body writes into a
 *   per-function cJSON buffer owned by fb_map_doc for the duration of
 *   one map_doc call.
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "fractal_bridge.h"
#include "sfs_core_bc.h"   /* luaJIT_BC_fractalsql_community[] + _SIZE */

/* ------------------------------------------------------------------ */
/* small helpers                                                      */
/* ------------------------------------------------------------------ */

static char *
xstrdup_fmt(const char *fmt, const char *arg)
{
    size_t n = strlen(fmt) + (arg ? strlen(arg) : 6) + 1;
    char  *p = (char *) malloc(n);
    if (p == NULL)
        return NULL;
    snprintf(p, n, fmt, arg ? arg : "(null)");
    return p;
}

/* Portable line reader. Grows *buf as needed; returns the number of
 * bytes read (excluding the trailing NUL), or -1 on EOF with nothing
 * read. POSIX getline() would suffice on glibc but does not exist in
 * MSVC CRT, so we roll our own. The trailing '\n' (and preceding
 * '\r' if present) is stripped. */
static long
read_line(FILE *fp, char **buf, size_t *cap)
{
    size_t len = 0;
    int    c;

    for (;;) {
        c = fgetc(fp);
        if (c == EOF) {
            if (len == 0)
                return -1;
            break;
        }
        if (len + 1 >= *cap) {
            size_t new_cap = *cap ? *cap * 2 : 4096;
            char  *nb      = (char *) realloc(*buf, new_cap);
            if (nb == NULL)
                return -1;
            *buf = nb;
            *cap = new_cap;
        }
        if (c == '\n')
            break;
        (*buf)[len++] = (char) c;
    }
    (*buf)[len] = '\0';
    if (len > 0 && (*buf)[len - 1] == '\r')
        (*buf)[--len] = '\0';
    return (long) len;
}

static void
write_log(const char *msg)
{
    /* CouchDB treats {"log":"..."} as a server-log line; useful for
     * surfacing errors without killing the query server. */
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "log", msg);
    char *s = cJSON_PrintUnformatted(o);
    fputs(s, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    free(s);
    cJSON_Delete(o);
}

/* ------------------------------------------------------------------ */
/* Lua <-> cJSON                                                      */
/* ------------------------------------------------------------------ */

static void lua_to_cjson_push(lua_State *L, int idx, cJSON *parent,
                              const char *key);

static int
lua_table_is_array(lua_State *L, int idx)
{
    /* Array iff every key is a positive integer 1..N with no holes.
     * Empty table is treated as array. */
    size_t len = lua_objlen(L, idx);  /* LuaJIT = 5.1 API */
    size_t seen = 0;

    lua_pushnil(L);
    while (lua_next(L, idx < 0 ? idx - 1 : idx) != 0) {
        if (lua_type(L, -2) != LUA_TNUMBER) {
            lua_pop(L, 2);
            return 0;
        }
        double k = lua_tonumber(L, -2);
        if (k < 1.0 || k > (double) len || (double) (size_t) k != k) {
            lua_pop(L, 2);
            return 0;
        }
        seen++;
        lua_pop(L, 1);
    }
    return seen == len;
}

static cJSON *
lua_to_cjson(lua_State *L, int idx)
{
    int t = lua_type(L, idx);

    switch (t) {
    case LUA_TNIL:
        return cJSON_CreateNull();

    case LUA_TBOOLEAN:
        return lua_toboolean(L, idx) ? cJSON_CreateTrue()
                                     : cJSON_CreateFalse();

    case LUA_TNUMBER:
        return cJSON_CreateNumber(lua_tonumber(L, idx));

    case LUA_TSTRING: {
        size_t      n;
        const char *s = lua_tolstring(L, idx, &n);
        /* cJSON_CreateString copies; safe even if Lua GC runs. */
        (void) n;
        return cJSON_CreateString(s);
    }

    case LUA_TTABLE: {
        int    is_arr = lua_table_is_array(L, idx);
        cJSON *out    = is_arr ? cJSON_CreateArray() : cJSON_CreateObject();
        int    abs    = idx < 0 ? lua_gettop(L) + idx + 1 : idx;

        lua_pushnil(L);
        while (lua_next(L, abs) != 0) {
            if (is_arr) {
                lua_to_cjson_push(L, -1, out, NULL);
            } else {
                /* key at -2: coerce to string without mutating the
                 * original (lua_tostring on a number mutates it, which
                 * would confuse lua_next). Push a copy. */
                lua_pushvalue(L, -2);
                const char *k = lua_tostring(L, -1);
                if (k == NULL)
                    k = "";
                lua_to_cjson_push(L, -2, out, k);
                lua_pop(L, 1);
            }
            lua_pop(L, 1);
        }
        return out;
    }

    default:
        return cJSON_CreateNull();
    }
}

static void
lua_to_cjson_push(lua_State *L, int idx, cJSON *parent, const char *key)
{
    cJSON *v = lua_to_cjson(L, idx);
    if (key != NULL)
        cJSON_AddItemToObject(parent, key, v);
    else
        cJSON_AddItemToArray(parent, v);
}

static void
cjson_to_lua(lua_State *L, const cJSON *n)
{
    if (n == NULL || cJSON_IsNull(n)) {
        lua_pushnil(L);
        return;
    }
    if (cJSON_IsBool(n)) {
        lua_pushboolean(L, cJSON_IsTrue(n));
        return;
    }
    if (cJSON_IsNumber(n)) {
        lua_pushnumber(L, n->valuedouble);
        return;
    }
    if (cJSON_IsString(n)) {
        lua_pushstring(L, n->valuestring);
        return;
    }
    if (cJSON_IsArray(n)) {
        lua_createtable(L, cJSON_GetArraySize(n), 0);
        int       i = 1;
        cJSON    *c;
        cJSON_ArrayForEach(c, n) {
            cjson_to_lua(L, c);
            lua_rawseti(L, -2, i++);
        }
        return;
    }
    if (cJSON_IsObject(n)) {
        lua_createtable(L, 0, 0);
        cJSON *c;
        cJSON_ArrayForEach(c, n) {
            cjson_to_lua(L, c);
            lua_setfield(L, -2, c->string);
        }
        return;
    }
    lua_pushnil(L);
}

/* ------------------------------------------------------------------ */
/* emit(key, value)  -- C closure, upvalue=fb_state*                  */
/* ------------------------------------------------------------------ */

static int
l_emit(lua_State *L)
{
    fb_state_t *s = (fb_state_t *) lua_touserdata(L, lua_upvalueindex(1));
    if (s == NULL || s->emit_buf == NULL)
        return luaL_error(L, "emit() called outside map_doc");

    if (lua_gettop(L) < 2) {
        lua_settop(L, 2);  /* pad missing value with nil */
    }

    cJSON *pair = cJSON_CreateArray();
    cJSON_AddItemToArray(pair, lua_to_cjson(L, 1));
    cJSON_AddItemToArray(pair, lua_to_cjson(L, 2));
    cJSON_AddItemToArray(s->emit_buf, pair);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Lua panic -- last-resort; should be rare since we pcall everything */
/* ------------------------------------------------------------------ */

static int
l_panic(lua_State *L)
{
    const char *msg = lua_tostring(L, -1);
    fprintf(stderr, "fractalsql-couch: LuaJIT panic: %s\n",
            msg ? msg : "(unknown)");
    /* CouchDB expects a JSON reply; emit one so the parent sees the
     * failure cleanly before we abort. */
    write_log(msg ? msg : "luajit panic");
    abort();
    return 0;  /* unreachable */
}

/* ------------------------------------------------------------------ */
/* fb_* bridge                                                        */
/* ------------------------------------------------------------------ */

int
fb_init(fb_state_t *s, char **err)
{
    int rc;

    memset(s, 0, sizeof *s);
    s->sfs_module_ref = LUA_NOREF;

    s->L = luaL_newstate();
    if (s->L == NULL) {
        if (err) *err = xstrdup_fmt("%s", "could not allocate LuaJIT state");
        return -1;
    }
    lua_atpanic(s->L, l_panic);
    luaL_openlibs(s->L);

    /* Register global emit(). Upvalue = fb_state* so l_emit can find
     * the active emit buffer without a registry round-trip. */
    lua_pushlightuserdata(s->L, s);
    lua_pushcclosure(s->L, l_emit, 1);
    lua_setglobal(s->L, "emit");

    /* Load embedded stripped bytecode; "=sfs_core" chunk name skips
     * the default "[string ...]" wrapping in tracebacks. */
    rc = luaL_loadbuffer(s->L,
                         (const char *) luaJIT_BC_fractalsql_community,
                         luaJIT_BC_fractalsql_community_SIZE,
                         "=sfs_core");
    if (rc != 0) {
        if (err) *err = xstrdup_fmt("loading sfs_core bytecode: %s",
                                    lua_tostring(s->L, -1));
        lua_close(s->L);
        s->L = NULL;
        return -1;
    }
    rc = lua_pcall(s->L, 0, 1, 0);
    if (rc != 0) {
        if (err) *err = xstrdup_fmt("initializing sfs_core: %s",
                                    lua_tostring(s->L, -1));
        lua_close(s->L);
        s->L = NULL;
        return -1;
    }
    s->sfs_module_ref = luaL_ref(s->L, LUA_REGISTRYINDEX);

    return 0;
}

void
fb_free(fb_state_t *s)
{
    if (s == NULL)
        return;
    if (s->L != NULL) {
        lua_close(s->L);
        s->L = NULL;
    }
    free(s->fun_refs);
    s->fun_refs     = NULL;
    s->fun_count    = 0;
    s->fun_capacity = 0;
}

void
fb_reset(fb_state_t *s)
{
    if (s == NULL || s->L == NULL)
        return;
    for (size_t i = 0; i < s->fun_count; i++)
        luaL_unref(s->L, LUA_REGISTRYINDEX, s->fun_refs[i]);
    s->fun_count = 0;
}

int
fb_add_fun(fb_state_t *s, const char *src, char **err)
{
    /* Wrap the source so `luaL_loadbuffer` produces a chunk that, when
     * called, returns the function value. CouchDB sends the function
     * literal itself as the payload. */
    size_t slen = strlen(src);
    size_t wlen = slen + 8;           /* "return " + src + NUL */
    char  *wrap = (char *) malloc(wlen);
    if (wrap == NULL) {
        if (err) *err = xstrdup_fmt("%s", "oom wrapping add_fun source");
        return -1;
    }
    memcpy(wrap, "return ", 7);
    memcpy(wrap + 7, src, slen + 1);

    int rc = luaL_loadbuffer(s->L, wrap, wlen - 1, "=add_fun");
    free(wrap);
    if (rc != 0) {
        if (err) *err = xstrdup_fmt("compile: %s", lua_tostring(s->L, -1));
        lua_pop(s->L, 1);
        return -1;
    }
    rc = lua_pcall(s->L, 0, 1, 0);
    if (rc != 0) {
        if (err) *err = xstrdup_fmt("eval: %s", lua_tostring(s->L, -1));
        lua_pop(s->L, 1);
        return -1;
    }
    if (lua_type(s->L, -1) != LUA_TFUNCTION) {
        if (err) *err = xstrdup_fmt("%s",
                                    "add_fun source did not yield a function");
        lua_pop(s->L, 1);
        return -1;
    }

    if (s->fun_count == s->fun_capacity) {
        size_t cap = s->fun_capacity ? s->fun_capacity * 2 : 4;
        int   *nr  = (int *) realloc(s->fun_refs, cap * sizeof *nr);
        if (nr == NULL) {
            if (err) *err = xstrdup_fmt("%s", "oom growing fun_refs");
            lua_pop(s->L, 1);
            return -1;
        }
        s->fun_refs     = nr;
        s->fun_capacity = cap;
    }
    s->fun_refs[s->fun_count++] = luaL_ref(s->L, LUA_REGISTRYINDEX);
    return 0;
}

cJSON *
fb_map_doc(fb_state_t *s, const cJSON *doc, char **err)
{
    cJSON *out = cJSON_CreateArray();

    for (size_t i = 0; i < s->fun_count; i++) {
        cJSON *per_fun = cJSON_CreateArray();
        s->emit_buf = per_fun;

        lua_rawgeti(s->L, LUA_REGISTRYINDEX, s->fun_refs[i]);
        cjson_to_lua(s->L, doc);

        int rc = lua_pcall(s->L, 1, 0, 0);
        if (rc != 0) {
            const char *msg = lua_tostring(s->L, -1);
            /* Report via log but keep the server alive; emit an empty
             * sub-array for this slot so positional order survives. */
            char buf[512];
            snprintf(buf, sizeof buf, "map fn %zu: %s",
                     i, msg ? msg : "(nil)");
            write_log(buf);
            lua_pop(s->L, 1);
            /* Any partial emits from this call are discarded. */
            cJSON_Delete(per_fun);
            per_fun = cJSON_CreateArray();
        }

        s->emit_buf = NULL;
        cJSON_AddItemToArray(out, per_fun);
    }

    (void) err;
    return out;
}

/* ------------------------------------------------------------------ */
/* Protocol loop                                                      */
/* ------------------------------------------------------------------ */

static void
write_json_line(cJSON *v)
{
    char *s = cJSON_PrintUnformatted(v);
    fputs(s, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    free(s);
}

static void
respond_true(void)
{
    fputs("true\n", stdout);
    fflush(stdout);
}

static void
handle_add_fun(fb_state_t *s, const cJSON *req)
{
    const cJSON *src = cJSON_GetArrayItem(req, 1);
    if (!cJSON_IsString(src) || src->valuestring == NULL) {
        write_log("add_fun: missing source string");
        return;
    }
    char *err = NULL;
    if (fb_add_fun(s, src->valuestring, &err) != 0) {
        write_log(err ? err : "add_fun: unknown error");
        free(err);
        return;
    }
    respond_true();
}

static void
handle_map_doc(fb_state_t *s, const cJSON *req)
{
    const cJSON *doc = cJSON_GetArrayItem(req, 1);
    if (doc == NULL) {
        write_log("map_doc: missing document");
        return;
    }
    char  *err = NULL;
    cJSON *r   = fb_map_doc(s, doc, &err);
    if (r == NULL) {
        write_log(err ? err : "map_doc: unknown error");
        free(err);
        return;
    }
    write_json_line(r);
    cJSON_Delete(r);
}

int
main(void)
{
    fb_state_t s;
    char      *err = NULL;

    if (fb_init(&s, &err) != 0) {
        fprintf(stderr, "fractalsql-couch: init failed: %s\n",
                err ? err : "(unknown)");
        free(err);
        return 1;
    }

    setvbuf(stdout, NULL, _IOLBF, 0);

    char   *line = NULL;
    size_t  cap  = 0;
    long    n;

    while ((n = read_line(stdin, &line, &cap)) != -1) {
        if (n == 0)
            continue;

        cJSON *req = cJSON_Parse(line);
        if (req == NULL || !cJSON_IsArray(req) || cJSON_GetArraySize(req) < 1) {
            write_log("malformed request: expected JSON array");
            cJSON_Delete(req);
            continue;
        }

        const cJSON *cmd = cJSON_GetArrayItem(req, 0);
        if (!cJSON_IsString(cmd) || cmd->valuestring == NULL) {
            write_log("malformed request: command must be a string");
            cJSON_Delete(req);
            continue;
        }

        if (strcmp(cmd->valuestring, "reset") == 0) {
            fb_reset(&s);
            respond_true();
        } else if (strcmp(cmd->valuestring, "add_fun") == 0) {
            handle_add_fun(&s, req);
        } else if (strcmp(cmd->valuestring, "map_doc") == 0) {
            handle_map_doc(&s, req);
        } else {
            char buf[128];
            snprintf(buf, sizeof buf, "unknown command: %s",
                     cmd->valuestring);
            write_log(buf);
        }

        cJSON_Delete(req);
    }

    free(line);
    fb_free(&s);
    return 0;
}
