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
#   --parallel               run the functional test groups in parallel (faster, but the groups
#                            share some per-user state and can fail each other; serial is the
#                            reference result)
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
PARALLEL=0
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
    --parallel) PARALLEL=1; shift ;;
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
VOL_OPT="Z"

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
# Optional: glibc-gconv-extra has the iconv modules (CP1251, GB18030, Shift_JIS, ...) that the
# 'fileencoding' tests use; the extra langpacks are not in UBI and are skipped.
RUN dnf -y --setopt=install_weak_deps=0 install \\
      gcc gcc-c++ make cmake gettext binutils git-core \\
      diffutils findutils procps-ng which file tar gzip patch util-linux \\
      glibc-langpack-en \\
 && dnf -y --setopt=install_weak_deps=0 --setopt=strict=0 install \\
      man-db unzip zip bzip2 xz glibc-gconv-extra clang-tools-extra glibc-langpack-de glibc-langpack-fr \\
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
as_tester() { runuser -u tester -- env PATH=/usr/local/bin:/usr/bin:/bin HOME=/home/tester LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
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
  as_tester "scripts/check-hardening.sh build/bin/wgvim build/compile_commands.json" \
    > "$OUT/hardening.txt" 2>&1
  status "hardening" "$(tail -1 "$OUT/hardening.txt" | sed 's/^hardening: //')"

  step "smoke tests"
  if as_tester "scripts/smoke-test.sh build/bin/wgvim" > "$OUT/smoke.log" 2>&1; then
    status "smoke tests" "ok"
  else
    status "smoke tests" "FAIL ($(tail -1 "$OUT/smoke.log" | sed 's/^smoke: FAIL: *//'); see smoke.log)"
  fi

  if [ "$RUN_FUNCTIONAL" = 1 ]; then
    step "functional tests"
    if [ "$PARALLEL" = 1 ]; then
      if as_tester "cmake --build build --target functionaltest-parallel -j $JOBS" \
           > "$OUT/functionaltest.log" 2>&1; then FT=ok; else FT=FAIL; fi
      as_tester "cmake --build build --target functionaltest-summary" \
        > "$OUT/functionaltest-summary.log" 2>&1 || true
      # Counts come from the per-group summaries (the parallel log interleaves the groups).
      SUM="$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/functionaltest-summary.log")"
    else
      if as_tester "cmake --build build --target functionaltest" \
           > "$OUT/functionaltest.log" 2>&1; then FT=ok; else FT=FAIL; fi
      SUM="$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/functionaltest.log")"
    fi
    P=$(awk '/^PASSED +[0-9]+ tests?/ {s+=$2} END {print s+0}' <<<"$SUM")
    SK=$(awk '/^ *[0-9]+ SKIPPED TESTS?/ {s+=$1} END {print s+0}' <<<"$SUM")
    FA=$(awk '/^ *[0-9]+ FAILED TESTS?/ {s+=$1} END {print s+0}' <<<"$SUM")
    ER=$(awk '/^ *[0-9]+ ERRORS?$/ {s+=$1} END {print s+0}' <<<"$SUM")
    grep -E '^(FAILED|ERROR) ' <<<"$SUM" | grep -vE '^(FAILED|ERROR) +[0-9]+ (tests?|errors?),' \
      > "$OUT/functionaltest-failures.txt" || true
    status "functional tests" "$FT (passed $P, skipped $SK, failed $FA, errors $ER; list in functionaltest-failures.txt)"
  fi

  if [ "$RUN_OLDTEST" = 1 ]; then
    step "old tests"
    if as_tester "make oldtest" > "$OUT/oldtest.log" 2>&1; then OT=ok; else OT=FAIL; fi
    cp "$SRC"/test/old/testdir/test.log "$OUT/oldtest-test.log" 2>/dev/null || true
    status "old tests" "$OT (see oldtest.log)"
  fi
fi

# Files written by root inside a docker container would be root-owned on the host.
# (Only set for docker: under rootless podman, root in the container already is the host user,
# and a chown to the host uid would map to a different, subordinate uid.)
[ -n "${HOST_UID:-}" ] && chown -R "$HOST_UID:$HOST_GID" "$OUT" 2>/dev/null
grep -qE 'FAIL|CHECK' "$OUT/summary.txt" && exit 1 || exit 0
INNER
chmod +x "$WORK_DIR/inner.sh"
cp "$OUT_DIR/source-version.txt" "$WORK_DIR/" 2>/dev/null || true

OWNER_OPTS=()
[ "$ENGINE" = docker ] && OWNER_OPTS=(-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)")
TTY_OPTS=()
[ "$OPEN_SHELL" = 1 ] && TTY_OPTS=(-it)

log "stage 2: offline build and test in $TOOL_IMAGE (--network none, $JOBS jobs)"
set +e
"$ENGINE" run --rm --network none \
  -e JOBS="$JOBS" -e BUILD_TYPE="$BUILD_TYPE" \
  -e RUN_FUNCTIONAL="$RUN_FUNCTIONAL" -e RUN_OLDTEST="$RUN_OLDTEST" -e OPEN_SHELL="$OPEN_SHELL" \
  -e PARALLEL="$PARALLEL" \
  ${OWNER_OPTS[@]+"${OWNER_OPTS[@]}"} \
  -v "$WORK_DIR:/work:ro,$VOL_OPT" -v "$OUT_DIR:/out:$VOL_OPT" \
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
