#!/bin/sh
# Verify that every vendored dependency listed in cmake.deps/deps.txt exists under
# deps/ and matches its pinned SHA256. Works offline. Exit status is non-zero if a
# file that is present has the wrong hash; absent files are reported but only
# fail the check with --strict (some dependencies are optional on Linux).
#
# Usage: scripts/verify-deps.sh [--strict]

set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
depsfile="$root/cmake.deps/deps.txt"
strict=0
[ "${1:-}" = "--strict" ] && strict=1

if command -v sha256sum >/dev/null 2>&1; then
  hash() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  hash() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "need sha256sum or shasum" >&2; exit 2
fi

bad=0; missing=0; ok=0
grep -E '^[A-Z0-9_]+_URL ' "$depsfile" | while read -r name path; do
  base=${name%_URL}
  want=$(grep -E "^${base}_SHA256 " "$depsfile" | cut -d' ' -f2)
  file="$root/$path"
  if [ ! -f "$file" ]; then
    printf 'MISSING   %-26s %s\n' "$base" "$path"
  elif [ "$(hash "$file")" = "$want" ]; then
    printf 'ok        %-26s %s\n' "$base" "$path"
  else
    printf 'BAD HASH  %-26s %s\n' "$base" "$path"
  fi
done | tee /tmp/verify-deps.$$

bad=$(grep -c '^BAD HASH' /tmp/verify-deps.$$ || true)
missing=$(grep -c '^MISSING' /tmp/verify-deps.$$ || true)
rm -f /tmp/verify-deps.$$
echo
echo "bad hash: $bad, missing: $missing"
[ "$bad" -eq 0 ] || exit 1
[ "$strict" -eq 0 ] || [ "$missing" -eq 0 ] || exit 1
