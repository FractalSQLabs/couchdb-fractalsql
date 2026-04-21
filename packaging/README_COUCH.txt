FractalSQL for Apache CouchDB — query server install notes
============================================================

fractalsql-couch is an external query server for Apache CouchDB that
speaks CouchDB's JSON-over-stdio protocol and embeds the FractalSQL
SFS/dFDB LuaJIT engine. One process per CouchDB worker; map functions
are compiled once and pinned in the LuaJIT state.

After installing the binary, register it as a query server in
CouchDB's local.ini.

  Linux (from .deb or .rpm):
    binary path  /usr/bin/fractalsql-couch
    local.ini    typically /opt/couchdb/etc/local.ini
                 or /etc/couchdb/local.ini

  Windows (from MSI):
    binary path  C:\Program Files\FractalSQL\CouchDB-Bridge\fractalsql-couch.exe
    local.ini    C:\CouchDB\etc\local.ini (adjust for your install)

  macOS (from .dmg / tarball):
    binary path  /usr/local/bin/fractalsql-couch (or wherever you placed it)
    local.ini    ~/Library/Application Support/CouchDB/etc/local.ini

local.ini snippet (add or merge into the [query_servers] section):

  [query_servers]
  ; Linux / macOS
  fractalsql = /usr/bin/fractalsql-couch

  ; Windows (escape backslashes or use forward slashes)
  ; fractalsql = C:/Program Files/FractalSQL/CouchDB-Bridge/fractalsql-couch.exe

Then restart CouchDB. Design documents can reference the server by
setting the `language` field on the ddoc to "fractalsql":

  {
    "_id": "_design/example",
    "language": "fractalsql",
    "views": {
      "by_name": {
        "map": "function(doc) if doc.name then emit(doc.name, 1) end end"
      }
    }
  }

Verifying the bridge is alive
-----------------------------

  $ echo '["reset"]' | /usr/bin/fractalsql-couch
  true

Reports and support
-------------------

  https://github.com/FractalSQLabs/couchdb-fractalsql/issues
