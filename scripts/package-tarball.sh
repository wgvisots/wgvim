#!/usr/bin/env bash
# Pack a built wgvim into a relocatable tarball, with a .sha256 file and its SBOM:
#   wgvim-1.0.0-linux-x86_64.tar.gz               (--release)
#   wgvim-1.0.0-1a2b3c4-linux-x86_64.tar.gz       (any other build: the version and the commit)
#
#   scripts/package-tarball.sh [--release] [--build DIR] [--deps DIR] [--out DIR]
#
#   --release     a release (RELEASING.md): the version must have no pre-release part ("-dev")
#                 and the tree no uncommitted changes; the name carries the version only
#   --build DIR   the CMake build directory (default: build)
#   --deps DIR    the bundled-dependencies build directory, for their licence files
#                 (default: .deps)
#   --out DIR     where the tarball goes (default: build/package)
#
# Output in --out: NAME.tar.gz, NAME.tar.gz.sha256 and NAME.spdx.json (the SPDX 2.3 SBOM,
# scripts/generate-sbom.py; also in the tarball as sbom.spdx.json).
#
# The tree inside is what "cmake --install" puts under its prefix (bin/, lib/wgvim/ or lib64/wgvim/,
# share/wgvim/runtime/, man pages, ...), plus LICENSE.txt, NOTICE, README.md, README-tarball.txt
# and licenses/ (the licence of every library built into wgvim or its parsers). wgvim finds its
# runtime files and parsers next to the binary, so the tree works wherever it is unpacked; the
# documented place is /opt/wgvim, which the SELinux policy labels (contrib/selinux/wgvim.fc).
#
# The archive is reproducible for a given build: sorted names, owner root, no timestamps but
# $SOURCE_DATE_EPOCH (default: the time of the last commit, else 0).
#
# Run from the top of the source tree, after the build. scripts/check-tarball.sh tests the result.

set -euo pipefail

BUILD=build
DEPS=.deps
OUT=build/package
RELEASE=0

die() { echo "package: error: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --build) BUILD="${2:?}"; shift 2 ;;
    --deps) DEPS="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --release) RELEASE=1; shift ;;
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BIN="$BUILD/bin/wgvim"
[ -x "$BIN" ] || die "$BIN not found; build first"
[ -d "$DEPS/build/src" ] || die "$DEPS/build/src not found (bundled dependency sources)"

# "WGVIM v1.0.0 (commit 1a2b3c4)" -> VERSION=1.0.0 COMMIT=1a2b3c4 ("1a2b3c4-dirty", or empty
# when the build did not know its commit).
FIRST="$("$BIN" --version | head -1)"
VERSION="$(sed -n 's/^WGVIM v\([^ ]*\).*/\1/p' <<<"$FIRST")"
COMMIT="$(sed -n 's/.* (commit \([^)]*\))$/\1/p' <<<"$FIRST")"
[ -n "$VERSION" ] || die "cannot read the version from: $FIRST"
ARCH="$(uname -m)"
if [ "$RELEASE" = 1 ]; then
  case "$VERSION" in *-*) die "--release, but the version $VERSION has a pre-release part" ;; esac
  case "$COMMIT" in
    "") die "--release, but the build does not know its commit" ;;
    *-dirty) die "--release, but the build has uncommitted changes ($COMMIT)" ;;
  esac
  NAME="wgvim-$VERSION-linux-$ARCH"
else
  case "$COMMIT" in
    *-dirty) echo "package: warning: built from a tree with uncommitted changes" >&2 ;;
  esac
  NAME="wgvim-$VERSION${COMMIT:+-$COMMIT}-linux-$ARCH"
fi

if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH="$(git log -1 --format=%ct 2>/dev/null || echo 0)"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
TREE="$STAGE/$NAME"

echo "package: installing into $NAME/"
cmake --install "$BUILD" --prefix "$TREE" --strip > "$STAGE/install.log" 2>&1 \
  || { cat "$STAGE/install.log" >&2; die "cmake --install failed"; }

# lib/ or lib64/ (GNUInstallDirs: lib64 on RHEL), as installed.
LIBDIR="$(cd "$TREE" && ls -d lib*/wgvim 2>/dev/null | head -1)"
[ -n "$LIBDIR" ] || die "no lib*/wgvim in the installed tree"

# Credit and licences: wgvim is Neovim (and Vim) with changes; NOTICE says so and lists them.
cp LICENSE.txt NOTICE README.md "$TREE/"
sed -e "s|@NAME@|$NAME|g" -e "s|@VERSION@|$VERSION|g" -e "s|@COMMIT@|${COMMIT:-unknown}|g" \
  -e "s|@LIBDIR@|$LIBDIR|g" \
  contrib/tarball/README.txt > "$TREE/README-tarball.txt"

# The SELinux policy and its installer, so the tarball alone is enough to confine wgvim.
mkdir -p "$TREE/share/wgvim/selinux"
cp contrib/selinux/wgvim.te contrib/selinux/wgvim.if contrib/selinux/wgvim.fc \
  scripts/wgvim-selinux.sh "$TREE/share/wgvim/selinux/"

# The licence of every bundled library that was built (the set in $DEPS/build/src is what this
# build used: on Linux that excludes gettext, libiconv, PUC Lua, wasmtime, win32yank), and of
# the code vendored under src/.
L="$TREE/licenses"
mkdir -p "$L"
for d in "$DEPS"/build/src/*/; do
  dep="$(basename "$d")"
  case "$dep" in *-build|*-stamp) continue ;; esac
  found=0
  for f in "$d"*; do
    case "$(basename "$f" | tr '[:upper:]' '[:lower:]')" in
      licen[cs]e*|copying*|copyright*|notice*)
        mkdir -p "$L/$dep"; cp "$f" "$L/$dep/"; found=1 ;;
    esac
  done
  [ "$found" = 1 ] || die "no licence file found for bundled dependency $dep"
done
for v in src/lpeg src/mpack src/xdiff src/nvim/vterm src/nvim/tui/termkey; do
  files="$(find "$v" -maxdepth 1 -type f \( -name 'LICENSE*' -o -name 'COPYING*' \))"
  [ -n "$files" ] || die "no licence file in $v"
  mkdir -p "$L/$(basename "$v")"
  cp $files "$L/$(basename "$v")/"
done
mkdir -p "$L/cjson" "$L/klib"
sed -n '1,/\*\//p' src/cjson/lua_cjson.c > "$L/cjson/LICENSE"
sed -n '1,/^$/p' src/klib/kvec.h > "$L/klib/LICENSE"
# Third-party files that wgvim added without their own licence file (NOTICE, "Provenance").
for d in contrib/third-party/*/; do
  mkdir -p "$L/$(basename "$d")"
  cp "$d"* "$L/$(basename "$d")/"
done

# Nothing in the tree may name the build machine's paths as a place to load code from.
if grep -rIl --exclude-dir=licenses -e "$ROOT/" "$TREE" >/dev/null 2>&1; then
  echo "package: note: text files that mention the build directory $ROOT:" >&2
  grep -rIl --exclude-dir=licenses -e "$ROOT/" "$TREE" | sed "s|^$STAGE/||" | head -20 >&2
fi

# Every library the programs and parsers need must come from the system (RHEL 9 base).
MISSING="$(find "$TREE/bin" "$TREE/$LIBDIR" -type f \( -perm -u+x -o -name '*.so' \) \
  -exec ldd {} + 2>/dev/null | grep 'not found' || true)"
[ -z "$MISSING" ] || die "missing libraries: $MISSING"

# The SBOM, inside the tree (it describes the files above) and next to the tarball.
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" python3 scripts/generate-sbom.py --tree "$TREE" \
  --name "$NAME" --deps-src "$DEPS/build/src" --out "$TREE/sbom.spdx.json"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cp "$TREE/sbom.spdx.json" "$OUT/$NAME.spdx.json"
TARBALL="$OUT/$NAME.tar.gz"
# Normalise modes: no group/other write, everything readable, directories and programs
# searchable/executable.
chmod -R u+rwX,go+rX,go-w "$TREE"
tar -C "$STAGE" --sort=name --format=posix \
  --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
  --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
  -cf - "$NAME" | gzip -9 -n > "$TARBALL"
(cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")

echo "package: $(du -h "$TARBALL" | cut -f1) $TARBALL"
echo "package: sha256 $(cut -d' ' -f1 "$TARBALL.sha256")"
