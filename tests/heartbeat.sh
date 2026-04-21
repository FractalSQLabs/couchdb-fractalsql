#!/usr/bin/env bash
# tests/heartbeat.sh
# Vertical-slice heartbeat for fractalsql-couch.
#
# Case 1: single map function, three simultaneous emits from one doc.
#         Proves the per-doc buffer batches 3 hits into one JSON line.
# Case 2: two map functions, asymmetric emit counts.
#         Proves positional isolation — each function's emits land in
#         its own sub-array and empty sub-arrays are preserved.
# Case 3: a doc that shouldn't match any fn predicate.
#         Proves the response is still a well-formed batch of empty
#         sub-arrays rather than a dropped line.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../fractalsql-couch"

if [[ ! -x "$BIN" ]]; then
    echo "heartbeat: $BIN not built. Run 'make' first." >&2
    exit 1
fi

pass=0
fail=0

run_case() {
    local name="$1"
    local input="$2"
    local expected="$3"

    local got
    got="$(printf '%s\n' "$input" | "$BIN")"

    if [[ "$got" == "$expected" ]]; then
        printf '  PASS  %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s\n' "$name"
        printf '    expected:\n%s\n' "$expected" | sed 's/^/      /'
        printf '    got:\n%s\n' "$got" | sed 's/^/      /'
        fail=$((fail + 1))
    fi
}

# ------------------------------------------------------------------ #
# Case 1: three emits from one map fn on one doc.                    #
# ------------------------------------------------------------------ #
FN1='function(doc) if doc.type == "person" then emit(doc.name, 1); emit(doc.age, 2); emit(doc.city, 3) end end'

IN1=$(cat <<EOF
["reset"]
["add_fun", $(printf '%s' "$FN1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
["map_doc", {"type":"person","name":"alice","age":30,"city":"NYC"}]
EOF
)

EXP1='true
true
[[["alice",1],[30,2],["NYC",3]]]'

run_case "3-emit batching in a single line" "$IN1" "$EXP1"

# ------------------------------------------------------------------ #
# Case 2: two fns, asymmetric emits, same doc.                       #
# ------------------------------------------------------------------ #
FN2A='function(doc) emit(doc.name, "A") end'
FN2B='function(doc) emit(doc.name, "B"); emit(doc.name, "C") end'

IN2=$(cat <<EOF
["reset"]
["add_fun", $(printf '%s' "$FN2A" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
["add_fun", $(printf '%s' "$FN2B" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
["map_doc", {"name":"zed"}]
EOF
)

EXP2='true
true
true
[[["zed","A"]],[["zed","B"],["zed","C"]]]'

run_case "multi-fn positional isolation" "$IN2" "$EXP2"

# ------------------------------------------------------------------ #
# Case 3: same two fns, but first fn is predicate-gated and skips.   #
# ------------------------------------------------------------------ #
FN3A='function(doc) if doc.type == "widget" then emit(doc.name, "A") end end'
FN3B='function(doc) emit(doc.name, "B") end'

IN3=$(cat <<EOF
["reset"]
["add_fun", $(printf '%s' "$FN3A" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
["add_fun", $(printf '%s' "$FN3B" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
["map_doc", {"type":"person","name":"qux"}]
EOF
)

EXP3='true
true
true
[[],[["qux","B"]]]'

run_case "empty sub-array preserves positional slot" "$IN3" "$EXP3"

# ------------------------------------------------------------------ #
printf '\n  %d passed, %d failed\n' "$pass" "$fail"
exit "$fail"
