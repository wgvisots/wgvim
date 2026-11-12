#!/bin/sh
# Install harper-ls (|wgvim-harper|) from Harper's VS Code extension package (a .vsix, which is
# a zip file), only if it is the pinned release: the .vsix and the harper-ls inside it must
# both match their SHA-256 in cmake.deps/deps.txt (HARPER_VSIX_SHA256, HARPER_LS_SHA256).
# Works offline.
#
# Usage: scripts/install-harper.sh [file.vsix]
#   file.vsix  default: the HARPER_VSIX_URL file in deps/
#   $PREFIX    where to install: $PREFIX/bin/harper-ls (default: ~/.local)
#
# ~/.local/bin is one of the directories wgvim's sandbox lets programs run from (see
# :help wgvim-sandbox); ~/.cargo/bin, where "cargo install" puts it, is not.

set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
depsfile="$root/cmake.deps/deps.txt"
prefix=${PREFIX:-$HOME/.local}

die() { echo "install-harper: $*" >&2; exit 1; }
pin() { grep -E "^$1 " "$depsfile" | cut -d' ' -f2; }

if command -v sha256sum >/dev/null 2>&1; then
  hash() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  hash() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "need sha256sum or shasum"
fi

vsix=${1:-$root/$(pin HARPER_VSIX_URL)}
want_vsix=$(pin HARPER_VSIX_SHA256)
want_bin=$(pin HARPER_LS_SHA256)
[ -n "$want_vsix" ] && [ -n "$want_bin" ] || die "no Harper pins in $depsfile"
[ -f "$vsix" ] || die "not found: $vsix"

got=$(hash "$vsix")
[ "$got" = "$want_vsix" ] || die "$vsix is not the pinned release
  SHA-256 $got
  wanted  $want_vsix"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
# Only the one member, flattened into the private temp directory: nothing else in the archive
# is written anywhere.
if command -v unzip >/dev/null 2>&1; then
  unzip -q -j -o "$vsix" extension/bin/harper-ls -d "$tmp" || die "no extension/bin/harper-ls in $vsix"
elif command -v python3 >/dev/null 2>&1; then
  python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, open(sys.argv[2], "wb") as out:
    out.write(z.read("extension/bin/harper-ls"))' "$vsix" "$tmp/harper-ls" ||
    die "no extension/bin/harper-ls in $vsix"
else
  die "need unzip or python3"
fi

got=$(hash "$tmp/harper-ls")
[ "$got" = "$want_bin" ] || die "harper-ls in $vsix does not match its pin
  SHA-256 $got
  wanted  $want_bin"

mkdir -p "$prefix/bin"
# Into place in one rename, so a running wgvim never starts a half-written file.
install -m 0755 "$tmp/harper-ls" "$prefix/bin/.harper-ls.new"
mv -f "$prefix/bin/.harper-ls.new" "$prefix/bin/harper-ls"
echo "installed $("$prefix/bin/harper-ls" --version) in $prefix/bin (SHA-256 $want_bin)"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "note: $prefix/bin is not in \$PATH" ;;
esac
