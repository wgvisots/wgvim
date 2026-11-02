#!/usr/bin/env bash
# Build and test wgvim inside a Red Hat UBI 9 (RHEL 9) container.
#
#   scripts/rhel9-container-test.sh [options]
#
# Stage 1 (needs network): pull the UBI 9 image and build a local toolchain image with the
#   compilers and tools from the UBI 9 repositories (dnf). This is the only step that uses
#   the network, and it never touches the wgvim sources.
# Stage 2 (no network): copy the source tree into a fresh container started with
#   --network none, then build (Release, with the bundled deps/ tarballs), check the
#   hardening of the binary, and run the functional and old test suites as a non-root user.
#
# Results go to ./rhel9-results/<timestamp>/ (summary.txt plus full logs).
#
# Options:
#   --engine podman|docker   container engine (default: podman if installed, else docker)
#   --image IMAGE            base image (default: registry.access.redhat.com/ubi9/ubi:latest)
#   --out DIR                results directory (default: ./rhel9-results)
#   --jobs N                 parallel build/test jobs (default: number of CPUs)
#   --build-type TYPE        CMake build type (default: Release)
#   --committed              test the last commit (git archive HEAD) instead of the working tree
#   --no-functional          skip the functional tests
#   --no-oldtest             skip the old (Vim) tests
#   --rebuild-image          rebuild the toolchain image even if it exists
#   --shell                  after the run, open a shell in the (offline) test container
#   -h, --help               show this help
#
# Exit status: 0 if the build succeeded and every selected test suite passed, 1 otherwise.

set -euo pipefail

ENGINE=""
BASE_IMAGE="registry.access.redhat.com/ubi9/ubi:latest"
TOOL_IMAGE="localhost/wgvim-rhel9-toolchain:latest"
OUT_ROOT="./rhel9-results"
JOBS=""
BUILD_TYPE="Release"
SOURCE_MODE="worktree"
RUN_FUNCTIONAL=1
RUN_OLDTEST=1
REBUILD_IMAGE=0
OPEN_SHELL=0

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; }
die() { echo "error: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --engine) ENGINE="${2:?}"; shift 2 ;;
    --image) BASE_IMAGE="${2:?}"; shift 2 ;;
    --out) OUT_ROOT="${2:?}"; shift 2 ;;
    --jobs) JOBS="${2:?}"; shift 2 ;;
    --build-type) BUILD_TYPE="${2:?}"; shift 2 ;;
    --committed) SOURCE_MODE="committed"; shift ;;
    --no-functional) RUN_FUNCTIONAL=0; shift ;;
    --no-oldtest) RUN_OLDTEST=0; shift ;;
    --rebuild-image) REBUILD_IMAGE=1; shift ;;
    --shell) OPEN_SHELL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO_ROOT/cmake.deps/deps.txt" ] || die "cannot find the wgvim source tree at $REPO_ROOT"

if [ -z "$ENGINE" ]; then
  if command -v podman >/dev/null 2>&1; then ENGINE=podman
  elif command -v docker >/dev/null 2>&1; then ENGINE=docker
  else die "neither podman nor docker is installed"; fi
fi
command -v "$ENGINE" >/dev/null 2>&1 || die "$ENGINE is not installed"
[ -n "$JOBS" ] || JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$(mkdir -p "$OUT_ROOT/$STAMP" && cd "$OUT_ROOT/$STAMP" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT_DIR/host.log"; }

# SELinux hosts (RHEL, Fedora) need a relabel on bind mounts; harmless elsewhere.
VOL_OPT=":Z"

# ---------------------------------------------------------------------------------------------
# Stage 1: toolchain image (network)
# ---------------------------------------------------------------------------------------------
if [ "$REBUILD_IMAGE" = 1 ] || ! "$ENGINE" image inspect "$TOOL_IMAGE" >/dev/null 2>&1; then
  log "stage 1: pulling $BASE_IMAGE and installing the toolchain (network)"
  "$ENGINE" pull "$BASE_IMAGE" 2>&1 | tee -a "$OUT_DIR/image.log"
  cat > "$WORK_DIR/Containerfile" <<EOF
FROM $BASE_IMAGE
# Required: compilers and build tools. ninja is not in the UBI repositories; without it the
# top-level Makefile uses "Unix Makefiles". gettext provides msgfmt for the translations.
RUN dnf -y --setopt=install_weak_deps=0 install \\
      gcc gcc-c++ make cmake gettext binutils git-core \\
      diffutils findutils procps-ng which file tar gzip patch util-linux \\
      glibc-langpack-en \\
 && dnf -y --setopt=install_weak_deps=0 --setopt=strict=0 install \\
      man-db unzip zip glibc-langpack-de glibc-langpack-fr \\
 && dnf clean all && rm -rf /var/cache/dnf
RUN useradd --create-home --shell /bin/bash tester
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
EOF
  "$ENGINE" build --pull=never -t "$TOOL_IMAGE" -f "$WORK_DIR/Containerfile" "$WORK_DIR" \
    2>&1 | tee -a "$OUT_DIR/image.log"
else
  log "stage 1: using existing toolchain image $TOOL_IMAGE (--rebuild-image to refresh)"
fi

# ---------------------------------------------------------------------------------------------
# Source snapshot
# ---------------------------------------------------------------------------------------------
log "packing sources ($SOURCE_MODE)"
SRC_TAR="$WORK_DIR/src.tar"
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  if [ "$SOURCE_MODE" = committed ]; then
    git -C "$REPO_ROOT" archive --format=tar -o "$SRC_TAR" HEAD
  else
    # Tracked files (with uncommitted edits) plus untracked files that are not ignored; build
    # directories are ignored and therefore left out.
    (cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard \
      | xargs -0 -r sh -c 'for f; do [ -e "$f" ] && printf "%s\0" "$f"; done' sh \
      | tar --null -T - -cf "$SRC_TAR")
  fi
  git -C "$REPO_ROOT" describe --always --dirty > "$OUT_DIR/source-version.txt" 2>/dev/null || true
else
  [ "$SOURCE_MODE" = worktree ] || die "--committed needs a git checkout"
  tar -C "$REPO_ROOT" --exclude='./build*' --exclude='./.deps' --exclude='./.git' \
      --exclude='./rhel9-results' -cf "$SRC_TAR" .
fi

# ---------------------------------------------------------------------------------------------
# Stage 2: offline build and test
# ---------------------------------------------------------------------------------------------
cat > "$WORK_DIR/inner.sh" <<'INNER'
#!/bin/bash
# Runs inside the container as root; the build and the tests run as user "tester".
set -uo pipefail
OUT=/out
SRC=/home/tester/wgvim
as_tester() { runuser -u tester -- env HOME=/home/tester LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
                MAKEFLAGS="-j$JOBS" bash -c "cd $SRC && $1"; }
status() { printf '%-28s %s\n' "$1" "$2" >> "$OUT/summary.txt"; }
step() { printf '\n== %s ==\n' "$*"; }

: > "$OUT/summary.txt"
{
  echo "wgvim RHEL 9 container test"
  echo "date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "image:       $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "kernel:      $(uname -r)"
  echo "compiler:    $(gcc --version | head -1)"
  echo "cmake:       $(cmake --version | head -1)"
  echo "source:      $(cat "$OUT/source-version.txt" 2>/dev/null || echo unknown)"
  echo "build type:  $BUILD_TYPE   jobs: $JOBS"
  echo
} >> "$OUT/summary.txt"

step "network check"
if getent hosts registry.access.redhat.com >/dev/null 2>&1; then
  status "network isolation" "FAIL (DNS resolves inside the test container)"
else
  status "network isolation" "ok (no network)"
fi

step "unpacking sources"
mkdir -p "$SRC" && tar -C "$SRC" -xf /work/src.tar && chown -R tester:tester "$SRC"

step "verifying vendored deps"
if as_tester "scripts/verify-deps.sh" > "$OUT/verify-deps.log" 2>&1; then
  status "deps/ checksums" "ok"
else
  status "deps/ checksums" "FAIL (see verify-deps.log)"
fi

step "building (offline)"
BUILD_OK=0
if as_tester "make CMAKE_BUILD_TYPE=$BUILD_TYPE" \
     > "$OUT/build.log" 2>&1; then
  BUILD_OK=1
  status "build" "ok"
else
  status "build" "FAIL (see build.log)"
fi

if [ "$BUILD_OK" = 1 ]; then
  BIN="$SRC/build/bin/wgvim"
  step "hardening check"
  {
    echo "# readelf checks on $BIN"
    readelf -hW "$BIN" | grep -E 'Type:'
    readelf -lW "$BIN" | grep -E 'GNU_RELRO|GNU_STACK'
    readelf -dW "$BIN" | grep -E 'BIND_NOW|FLAGS'
    readelf -nW "$BIN" | grep -iE 'x86 feature|properties' || true
    echo "# fortified libc calls (__*_chk):"
    readelf --dyn-syms -W "$BIN" | grep -oE '__[a-z_]+_chk' | sort -u | tr '\n' ' '; echo
    echo "# stack protector:"
    readelf --dyn-syms -W "$BIN" | grep -oE '__stack_chk_fail' | sort -u
    echo "# hardening flags in the compile commands:"
    grep -oE -- '-D_FORTIFY_SOURCE=[0-9]|-fstack-protector-strong|-fstack-clash-protection|-fcf-protection=full|-ftrivial-auto-var-init=zero|-fno-strict-overflow' \
      "$SRC/build/compile_commands.json" 2>/dev/null | sort -u
  } > "$OUT/hardening.txt" 2>&1
  H=""
  readelf -hW "$BIN" | grep -q 'DYN' && H="$H PIE" || H="$H no-PIE!"
  readelf -lW "$BIN" | grep -q GNU_RELRO && H="$H RELRO" || H="$H no-RELRO!"
  readelf -dW "$BIN" | grep -qE 'BIND_NOW|FLAGS.*NOW' && H="$H BIND_NOW" || H="$H lazy-binding!"
  readelf -lW "$BIN" | grep GNU_STACK | grep -q 'RWE' && H="$H exec-stack!" || H="$H NX-stack"
  readelf --dyn-syms -W "$BIN" | grep -q '__stack_chk_fail' && H="$H stack-protector" || H="$H no-stack-protector!"
  readelf --dyn-syms -W "$BIN" | grep -qE '__[a-z_]+_chk' && H="$H FORTIFY" || H="$H no-FORTIFY!"
  F="$(grep -oE -- '-D_FORTIFY_SOURCE=[0-9]' "$SRC/build/compile_commands.json" 2>/dev/null | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}')"
  case "$H" in *'!'*) status "hardening" "CHECK:$H ($F)" ;; *) status "hardening" "ok:$H ($F)" ;; esac

  step "smoke tests"
  {
    as_tester "build/bin/wgvim --version"
    echo "--- v:servername at startup (expected empty):"
    as_tester "build/bin/wgvim --clean --headless -c 'echo \"[\" .. v:servername .. \"]\"' -c 'qa!' 2>&1"
    echo
    echo "--- immutable options (expected E519 twice):"
    as_tester "build/bin/wgvim --clean --headless -c 'try | set exrc | catch | echo v:exception | endtry' -c 'try | set modelineexpr | catch | echo v:exception | endtry' -c 'qa!' 2>&1"
    echo
    echo "--- :checkhealth vim.health (first lines):"
    as_tester "build/bin/wgvim --clean --headless -c 'checkhealth vim.health' -c 'w! /tmp/health.txt' -c 'qa!' >/dev/null 2>&1; head -40 /tmp/health.txt"
  } > "$OUT/smoke.log" 2>&1
  if grep -q '^WGVIM v' "$OUT/smoke.log" && grep -q '^\[\]' "$OUT/smoke.log" \
     && [ "$(grep -c E519 "$OUT/smoke.log")" -ge 2 ]; then
    status "smoke tests" "ok"
  else
    status "smoke tests" "FAIL (see smoke.log)"
  fi

  if [ "$RUN_FUNCTIONAL" = 1 ]; then
    step "functional tests"
    if as_tester "cmake --build build --target functionaltest-parallel -j $JOBS" \
         > "$OUT/functionaltest.log" 2>&1; then FT=ok; else FT=FAIL; fi
    as_tester "cmake --build build --target functionaltest-summary" \
      > "$OUT/functionaltest-summary.log" 2>&1 || true
    P=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/functionaltest.log" | awk '/^PASSED +[0-9]+ tests/ {s+=$2} END {print s+0}')
    FA=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/functionaltest.log" | awk '/^ *[0-9]+ FAILED TESTS?/ {s+=$1} END {print s+0}')
    ER=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/functionaltest.log" | awk '/^ *[0-9]+ ERRORS?/ {s+=$1} END {print s+0}')
    sed 's/\x1b\[[0-9;]*m//g' "$OUT/functionaltest.log" | grep -E '^(FAILED|ERROR) +[^ ]+ @ ' \
      | sort -u > "$OUT/functionaltest-failures.txt" || true
    status "functional tests" "$FT (passed $P, failed $FA, errors $ER; list in functionaltest-failures.txt)"
  fi

  if [ "$RUN_OLDTEST" = 1 ]; then
    step "old tests"
    if as_tester "make oldtest" > "$OUT/oldtest.log" 2>&1; then OT=ok; else OT=FAIL; fi
    cp "$SRC"/test/old/testdir/test.log "$OUT/oldtest-test.log" 2>/dev/null || true
    status "old tests" "$OT (see oldtest.log)"
  fi
fi

# Files written by root inside a docker container would be root-owned on the host.
[ -n "${HOST_UID:-}" ] && chown -R "$HOST_UID:$HOST_GID" "$OUT" 2>/dev/null
grep -qE 'FAIL' "$OUT/summary.txt" && exit 1 || exit 0
INNER
chmod +x "$WORK_DIR/inner.sh"
cp "$OUT_DIR/source-version.txt" "$WORK_DIR/" 2>/dev/null || true

TTY_OPTS=()
[ "$OPEN_SHELL" = 1 ] && TTY_OPTS=(-it)

log "stage 2: offline build and test in $TOOL_IMAGE (--network none, $JOBS jobs)"
set +e
"$ENGINE" run --rm --network none \
  -e JOBS="$JOBS" -e BUILD_TYPE="$BUILD_TYPE" \
  -e RUN_FUNCTIONAL="$RUN_FUNCTIONAL" -e RUN_OLDTEST="$RUN_OLDTEST" -e OPEN_SHELL="$OPEN_SHELL" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v "$WORK_DIR:/work:ro$VOL_OPT" -v "$OUT_DIR:/out$VOL_OPT" \
  ${TTY_OPTS[@]+"${TTY_OPTS[@]}"} \
  "$TOOL_IMAGE" \
  bash -c '/work/inner.sh; rc=$?; if [ "$OPEN_SHELL" = 1 ]; then echo "(offline test container; exit to finish)"; bash; fi; exit $rc' \
  2>&1 | tee "$OUT_DIR/container.log"
RC=${PIPESTATUS[0]}
set -e

echo
cat "$OUT_DIR/summary.txt" 2>/dev/null || log "no summary was written; see $OUT_DIR/container.log"
echo
log "results: $OUT_DIR"
exit "$RC"
