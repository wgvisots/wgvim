#!/usr/bin/env bash
# Test a release tarball from scripts/package-tarball.sh the way a user gets it: unpacked into
# a new directory (and then moved), with no source tree.
#
#   scripts/check-tarball.sh TARBALL
#
# Needs only bash, coreutils, tar, gzip (and ldd, if present). scripts/smoke-test.sh must be next
# to this script. Run it as a normal user; the RHEL 9 job runs it in a plain UBI 9 container
# (no compilers, no network) with decoy wgvim files at the compiled-in /opt/wgvim, to check that
# a moved tree uses its own runtime files and parsers.
#
# Prints what it checked and a last line "check-tarball: ok" or "check-tarball: FAIL: ...".

set -uo pipefail

TARBALL="${1:?usage: check-tarball.sh TARBALL}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$TARBALL" ] || { echo "error: $TARBALL not found" >&2; exit 2; }
TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAIL=""
fail() { echo "  FAIL: $*"; FAIL="$FAIL; $*"; }

echo "--- checksum:"
if [ -f "$TARBALL.sha256" ]; then
  (cd "$(dirname "$TARBALL")" && sha256sum -c "$(basename "$TARBALL").sha256") \
    || fail "checksum"
else
  echo "  (no .sha256 file)"
fi

echo "--- archive layout:"
NAME="$(basename "$TARBALL" .tar.gz)"
# Listed once: "tar | grep -q" fails under pipefail when grep stops reading early.
LIST="$(tar -tzf "$TARBALL")" || fail "listing the archive"
VLIST="$(tar -tvzf "$TARBALL")"
TOP="$(cut -d/ -f1 <<<"$LIST" | sort -u)"
[ "$TOP" = "$NAME" ] || fail "expected one top-level directory $NAME, got: $(echo $TOP)"
OWNERS="$(awk '{print $2}' <<<"$VLIST" | sort -u)"
[ "$OWNERS" = "0/0" ] || fail "files not owned by 0/0: $(echo $OWNERS)"
WRITABLE="$(awk '$1 ~ /^.....w|^........w/ {print $NF}' <<<"$VLIST" | head -5)"
[ -z "$WRITABLE" ] || fail "group/other-writable: $WRITABLE"
has() { grep -qE "^$NAME/$1/?\$" <<<"$LIST"; }
for f in bin/wgvim share/wgvim/runtime/doc/tags LICENSE.txt NOTICE \
         README-tarball.txt licenses/unibilium share/wgvim/selinux/wgvim.te sbom.spdx.json; do
  has "$f" || fail "missing $f"
done
# The parsers: lib/ or lib64/ (GNUInstallDirs: lib64 on RHEL).
has 'lib(64)?/wgvim/parser/c\.so' || fail "missing lib*/wgvim/parser/c.so"
echo "  $(wc -l <<<"$LIST") entries under $NAME/"

mkdir -p "$T/first" "$T/second/elsewhere"
tar -C "$T/first" -xzf "$TARBALL" || fail "unpacking"

# Where the tree is found from: $VIMRUNTIME and the C parser must both be inside $1.
check_paths() {
  local tree="$1" out
  out="$(cd "$T" && env -u VIMRUNTIME -u VIM HOME="$T/home" XDG_CONFIG_HOME="$T/cfg" \
           XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" \
           timeout 60 "$tree/bin/wgvim" --clean --headless \
           -c 'lua io.stdout:write("rt=", vim.env.VIMRUNTIME or "", "\n")' \
           -c 'lua io.stdout:write("parser=", vim.api.nvim_get_runtime_file("parser/c.so", false)[1] or "", "\n")' \
           -c 'lua local ok, r = pcall(vim.treesitter.language.add, "c"); io.stdout:write("highlight=", tostring(ok and r == true), "\n")' \
           -c 'try | help wgvim | echo "" | catch | echo "help=" .. v:exception | endtry' \
           -c 'qa!' 2>&1)"
  echo "$out" | sed 's/^/  /'
  local rt parser
  rt="$(sed -n 's/^rt=//p' <<<"$out")"
  parser="$(sed -n 's/^parser=//p' <<<"$out")"
  [ "$rt" = "$tree/share/wgvim/runtime" ] || fail "VIMRUNTIME is '$rt', not inside $tree"
  case "$parser" in "$tree"/lib/wgvim/parser/c.so|"$tree"/lib64/wgvim/parser/c.so) ;; *) fail "C parser from '$parser', not $tree" ;; esac
  grep -q '^highlight=true' <<<"$out" || fail "the C parser does not load"
  ! grep -q '^help=' <<<"$out" || fail ":help wgvim does not work"
}

echo "--- unpacked at $T/first/$NAME (VIMRUNTIME unset):"
"$T/first/$NAME/bin/wgvim" --version | head -1 | sed 's/^/  /'
check_paths "$T/first/$NAME"

echo "--- moved to $T/second/elsewhere/wgvim:"
mv "$T/first/$NAME" "$T/second/elsewhere/wgvim"
TREE="$T/second/elsewhere/wgvim"
check_paths "$TREE"

echo "--- symlink to the binary:"
mkdir -p "$T/bin" && ln -s "$TREE/bin/wgvim" "$T/bin/wgvim"
check_paths_link="$(env -u VIMRUNTIME timeout 60 "$T/bin/wgvim" --clean --headless \
  -c 'lua io.stdout:write(vim.env.VIMRUNTIME or "", "\n")' -c 'qa!' 2>&1)"
echo "  $check_paths_link"
[ "$check_paths_link" = "$TREE/share/wgvim/runtime" ] || fail "through a symlink, VIMRUNTIME is '$check_paths_link'"

if command -v ldd >/dev/null 2>&1; then
  echo "--- shared libraries (from the system):"
  LIBS="$(find "$TREE/bin" "$TREE"/lib* -type f \( -perm -u+x -o -name '*.so' \) \
            ! -name '*.sh' -exec ldd {} + 2>/dev/null)"
  grep 'not found' <<<"$LIBS" && fail "missing shared libraries"
  grep -oE '^\s+[^ ]+\.so[^ ]*' <<<"$LIBS" | sort -u | tr -d '\t ' | tr '\n' ' ' | sed 's/^/  /'
  echo
fi

echo "--- SBOM (sbom.spdx.json):"
if command -v python3 >/dev/null 2>&1; then
  # Every file of the tree but the SBOM is listed, with the right SHA256, and nothing else;
  # the copy next to the tarball (if any) is the same document.
  python3 -I - "$TREE" "${TARBALL%.tar.gz}.spdx.json" <<'PY' || fail "SBOM does not match the tree"
import hashlib, json, os, sys
tree, beside = sys.argv[1], sys.argv[2]
raw = open(os.path.join(tree, 'sbom.spdx.json'), 'rb').read()
doc = json.loads(raw)
assert doc['spdxVersion'] == 'SPDX-2.3', doc['spdxVersion']
listed = {f['fileName'][2:]: next(c['checksumValue'] for c in f['checksums']
                                  if c['algorithm'] == 'SHA256') for f in doc['files']}
actual = {}
for d, _, fs in os.walk(tree):
    for fn in fs:
        rel = os.path.relpath(os.path.join(d, fn), tree)
        if rel != 'sbom.spdx.json':
            actual[rel] = hashlib.sha256(open(os.path.join(tree, rel), 'rb').read()).hexdigest()
bad = sorted(set(listed) ^ set(actual)) + sorted(k for k in listed if k in actual and listed[k] != actual[k])
if bad:
    print('  mismatched: ' + ', '.join(bad[:10]))
    sys.exit(1)
wg = next(p for p in doc['packages'] if p['name'] == 'wgvim')
print('  %s %s: %d files match, %d packages' % (wg['name'], wg['versionInfo'], len(listed), len(doc['packages'])))
if os.path.exists(beside) and open(beside, 'rb').read() != raw:
    print('  %s differs from the one in the tarball' % os.path.basename(beside))
    sys.exit(1)
PY
else
  echo "  (no python3: only checked that it is there)"
fi

if [ -x "$TREE/bin/tablefmt" ]; then
  echo "--- tablefmt:"
  OUT="$(printf 'int a = 1;\nint bb = 22;\n' | "$TREE/bin/tablefmt")" || fail "tablefmt exit status"
  echo "$OUT" | sed 's/^/  /'
  [ "$(wc -l <<<"$OUT")" = 2 ] || fail "tablefmt output"
fi

echo "--- smoke tests (installed runtime):"
SMOKE="$(VIMRUNTIME="$TREE/share/wgvim/runtime" "$HERE/smoke-test.sh" "$TREE/bin/wgvim" 2>&1)"
echo "$SMOKE" | sed 's/^/  /'
[ "$(tail -1 <<<"$SMOKE")" = "smoke: ok" ] || fail "smoke tests"

if [ -z "$FAIL" ]; then
  echo "check-tarball: ok"
else
  echo "check-tarball: FAIL:${FAIL#;}"
  exit 1
fi
