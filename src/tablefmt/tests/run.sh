#!/usr/bin/env bash
# Regression tests: clang-format + tablefmt on each tests/cases/*.in.cpp must
# match the .expected.cpp file, change only whitespace, and be idempotent.
#   tests/run.sh [path/to/tablefmt] [path/to/clang-format]
#   tests/run.sh --update ...   rewrite the .expected.cpp files
set -u
update=0
if [ "${1:-}" = "--update" ]; then update=1; shift; fi
here="$(cd "$(dirname "$0")" && pwd)"
tf="${1:-$here/../build/tablefmt}"
cf="${2:-clang-format}"
style="--style=file:$here/../.clang-format"
fail=0

for in in "$here"/cases/*.in.cpp; do
    exp="${in%.in.cpp}.expected.cpp"
    name="$(basename "${in%.in.cpp}")"
    got="$("$cf" "$style" "$in" | "$tf")"
    if [ $update = 1 ]; then printf '%s\n' "$got" > "$exp"; echo "updated $name"; continue; fi
    if [ "$got" != "$(cat "$exp")" ]; then
        echo "FAIL $name: output differs"; diff <(printf '%s\n' "$got") "$exp" | head -20; fail=1
    fi
    if [ "$(printf '%s' "$got" | "$tf")" != "$got" ]; then echo "FAIL $name: not idempotent (tablefmt alone)"; fail=1; fi
    if [ "$(printf '%s\n' "$got" | "$cf" "$style" --assume-filename=x.cpp | "$tf")" != "$got" ]; then
        echo "FAIL $name: not idempotent (clang-format | tablefmt)"; fail=1
    fi
    if [ "$("$cf" "$style" "$in" | tr -d ' \t\n')" != "$(printf '%s' "$got" | tr -d ' \t\n')" ]; then
        echo "FAIL $name: changed something other than whitespace"; fail=1
    fi
done
[ $fail = 0 ] && echo "all tests passed"
exit $fail
