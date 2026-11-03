#!/usr/bin/env bash
# Quick checks of wgvim's restrictions on a built binary.
#
#   scripts/smoke-test.sh [BINARY]        (default: build/bin/wgvim)
#
# Checks that the binary runs, that no RPC server is started unless asked, that 'exrc' and
# 'modelineexpr' cannot be set, and that :checkhealth runs. Prints what it saw and a last line
# "smoke: ok" or "smoke: FAIL: ...". Exit status 0 or 1.

set -uo pipefail

BIN="${1:-build/bin/wgvim}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -x "$BIN" ] || { echo "error: $BIN is not an executable" >&2; exit 2; }
export VIMRUNTIME="${VIMRUNTIME:-$ROOT/runtime}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Keep the user's own config and state out of it.
export XDG_CONFIG_HOME="$TMP/config" XDG_DATA_HOME="$TMP/data" XDG_STATE_HOME="$TMP/state"
export XDG_CACHE_HOME="$TMP/cache"
# The scratch directory is outside the current directory, so the sandbox must allow it.
run() { timeout 60 "$BIN" --clean --headless --sandbox-allow "$TMP" "$@" 2>&1; }
FAIL=""

echo "--- version:"
V="$(timeout 60 "$BIN" --version 2>&1)"; echo "$V"
grep -q '^WGVIM v' <<<"$V" || FAIL="$FAIL version"

echo "--- v:servername at startup (expected []):"
S="$(run -c 'echo "[" .. v:servername .. "]"' -c 'qa!')"; echo "$S"
grep -q '^\[\]' <<<"$S" || FAIL="$FAIL servername"

echo "--- immutable options (expected E519 twice):"
O="$(run -c 'try | set exrc | catch | echo v:exception | endtry' \
         -c 'try | set modelineexpr | catch | echo v:exception | endtry' -c 'qa!')"; echo "$O"
[ "$(grep -c E519 <<<"$O")" -ge 2 ] || FAIL="$FAIL immutable-options"

echo "--- :checkhealth vim.health (first lines):"
# :checkhealth fills its buffer asynchronously.
run -c 'checkhealth vim.health' \
    -c 'lua vim.wait(30000, function() return vim.api.nvim_buf_line_count(0) > 3 end, 100)' \
    -c "w! $TMP/health.txt" -c 'qa!' >/dev/null
if [ "$(wc -l < "$TMP/health.txt" 2>/dev/null || echo 0)" -gt 3 ]; then head -40 "$TMP/health.txt"; else FAIL="$FAIL checkhealth"; fi

echo "--- sandbox (informational; needs Landlock, Linux 5.13+ / RHEL 9.6+):"
run -c 'lua local i = vim.api.nvim__sandbox_info()
  io.stdout:write(("%s (ABI %d, network %s, %d rules) %s\n"):format(
    i.status, i.abi, tostring(i.network), #i.rules, i.reason))' -c 'qa!'

if [ -n "$FAIL" ]; then echo "smoke: FAIL:$FAIL"; exit 1; fi
echo "smoke: ok"
