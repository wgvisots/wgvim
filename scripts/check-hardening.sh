#!/usr/bin/env bash
# Check that a wgvim binary was built with the hardening flags (see WGVIM_HARDENING).
#
#   scripts/check-hardening.sh [BINARY] [COMPILE_COMMANDS_JSON]
#
# Defaults: build/bin/wgvim and build/compile_commands.json. Prints the details, then a last
# line "hardening: ok: ..." or "hardening: CHECK: ..." (missing items end in "!").
# Exit status: 0 if everything is present, 1 if something is missing, 2 on usage errors.
#
# IBT is not checked: LuaJIT's hand-written VM (lj_vm.o) has no IBT marking, so the linker drops
# it for the whole binary (see SECURITY-AUDIT.md).

set -uo pipefail

BIN="${1:-build/bin/wgvim}"
CC_JSON="${2:-$(dirname "$BIN")/../compile_commands.json}"
[ -x "$BIN" ] || { echo "error: $BIN is not an executable" >&2; exit 2; }
command -v readelf >/dev/null 2>&1 || { echo "error: readelf not found (binutils)" >&2; exit 2; }

# Capture readelf output first: "readelf | grep -q" can fail under pipefail (SIGPIPE).
EH="$(readelf -hW "$BIN")"
EL="$(readelf -lW "$BIN")"
ED="$(readelf -dW "$BIN")"
EN="$(readelf -nW "$BIN" 2>/dev/null)"
ES="$(readelf --dyn-syms -W "$BIN")"
FLAGS=""
[ -f "$CC_JSON" ] && FLAGS="$(grep -oE -- '-D_FORTIFY_SOURCE=[0-9]|-fstack-protector-strong|-fstack-clash-protection|-fcf-protection=full|-ftrivial-auto-var-init=zero|-fno-strict-overflow' "$CC_JSON" | sort | uniq -c | sort -rn)"

echo "# readelf checks on $BIN"
grep -E 'Type:' <<<"$EH"
grep -E 'GNU_RELRO|GNU_STACK' <<<"$EL"
grep -E 'BIND_NOW|FLAGS' <<<"$ED"
grep -iE 'x86 feature' <<<"$EN" || true
echo "# fortified libc calls (__*_chk):"
grep -oE '__[a-z_]+_chk' <<<"$ES" | grep -v '^__stack_chk$' | sort -u | tr '\n' ' '; echo
echo "# stack protector:"
grep -oE '__stack_chk_fail' <<<"$ES" | sort -u
echo "# hardening flags in the compile commands (count, flag):"
if [ -n "$FLAGS" ]; then echo "$FLAGS"; else echo "(no $CC_JSON)"; fi

H=""
grep -q 'DYN' <<<"$EH" && H="$H PIE" || H="$H no-PIE!"
grep -q GNU_RELRO <<<"$EL" && H="$H RELRO" || H="$H no-RELRO!"
grep -qE 'BIND_NOW|FLAGS.*NOW' <<<"$ED" && H="$H BIND_NOW" || H="$H lazy-binding!"
grep GNU_STACK <<<"$EL" | grep -q 'RWE' && H="$H exec-stack!" || H="$H NX-stack"
grep -q '__stack_chk_fail' <<<"$ES" && H="$H stack-protector" || H="$H no-stack-protector!"
grep -oE '__[a-z_]+_chk' <<<"$ES" | grep -qv '^__stack_chk' && H="$H FORTIFY" || H="$H no-FORTIFY!"
if grep -q 'SHSTK' <<<"$EN"; then H="$H SHSTK"; fi
F="$(awk 'NR==1 && /FORTIFY/ {print $2}' <<<"$(grep FORTIFY <<<"$FLAGS")")"
[ -n "$F" ] && H="$H ($F)"

case "$H" in
  *'!'*) echo "hardening: CHECK:$H"; exit 1 ;;
  *) echo "hardening: ok:$H"; exit 0 ;;
esac
