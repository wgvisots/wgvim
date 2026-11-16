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
# Stage 3 (with --package, no network): pack the tested binary into the release tarball
#   (scripts/package-tarball.sh) and test it in a fresh container of the plain base image, with
#   no compilers and no source tree, as a non-root user (scripts/check-tarball.sh).
#
# Results go to ./rhel9-results/<timestamp>/ (summary.txt plus full logs); with --package, the
# tarball and its .sha256 go to ./rhel9-results/<timestamp>/package/.
#
# Options:
#   --engine podman|docker   container engine (default: podman if installed, else docker)
#   --image IMAGE            base image (default: registry.access.redhat.com/ubi9/ubi:latest)
#   --out DIR                results directory (default: ./rhel9-results)
#   --jobs N                 parallel build/test jobs (default: number of CPUs)
#   --build-type TYPE        CMake build type (default: Release)
#   --committed              test the last commit (git archive HEAD) instead of the working tree
#   --package                build for /opt/wgvim and make the release tarball (stage 3);
#                            with --committed, its name and --version carry the commit
#   --release                with --package: a release tarball (RELEASING.md), named by the
#                            version alone; refused for a "-dev" version or uncommitted changes
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
PACKAGE=0
RELEASE=0

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
    --package) PACKAGE=1; shift ;;
    --release) RELEASE=1; shift ;;
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
# python3 (3.9) writes the release tarball's SBOM (scripts/generate-sbom.py).
# Optional: glibc-gconv-extra has the iconv modules (CP1251, GB18030, Shift_JIS, ...) that the
# 'fileencoding' tests use; the extra langpacks are not in UBI and are skipped.
RUN dnf -y --setopt=install_weak_deps=0 install \\
      gcc gcc-c++ make cmake gettext binutils git-core python3 \\
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
SOURCE_DATE_EPOCH=0
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
  # The tarball's file times: the commit time (reproducible archives).
  SOURCE_DATE_EPOCH="$(git -C "$REPO_ROOT" log -1 --format=%ct 2>/dev/null || echo 0)"
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
# The release tarball is meant for /opt/wgvim (labelled by the SELinux policy): that becomes the
# compiled-in fallback; the tree still finds its files next to the binary wherever it is.
PREFIX_OPT=""
[ "$PACKAGE" = 1 ] && PREFIX_OPT="CMAKE_INSTALL_PREFIX=/opt/wgvim"
if as_tester "make CMAKE_BUILD_TYPE=$BUILD_TYPE $PREFIX_OPT" \
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

  if [ "$PACKAGE" = 1 ]; then
    # Before the test suites, so nothing they leave in build/ can end up in the tarball.
    step "release tarball"
    RELEASE_OPT=""
    [ "$RELEASE" = 1 ] && RELEASE_OPT="--release"
    if as_tester "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH scripts/package-tarball.sh $RELEASE_OPT --out package" \
         > "$OUT/package.log" 2>&1; then
      mkdir -p "$OUT/package" && cp "$SRC"/package/* "$OUT/package/"
      status "release tarball" "ok ($(cd "$OUT/package" && ls *.tar.gz))"
      # The installed binary is stripped: check that it is still the hardened one.
      as_tester "d=\$(mktemp -d) && tar -C \$d -xzf package/*.tar.gz \
                 && scripts/check-hardening.sh \$d/*/bin/wgvim build/compile_commands.json; \
                 rc=\$?; rm -rf \$d; exit \$rc" > "$OUT/package-hardening.txt" 2>&1
      status "tarball hardening" "$(tail -1 "$OUT/package-hardening.txt" | sed 's/^hardening: //')"
    else
      status "release tarball" "FAIL ($(tail -1 "$OUT/package.log"); see package.log)"
    fi
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
  -e PARALLEL="$PARALLEL" -e PACKAGE="$PACKAGE" -e RELEASE="$RELEASE" -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  ${OWNER_OPTS[@]+"${OWNER_OPTS[@]}"} \
  -v "$WORK_DIR:/work:ro,$VOL_OPT" -v "$OUT_DIR:/out:$VOL_OPT" \
  ${TTY_OPTS[@]+"${TTY_OPTS[@]}"} \
  "$TOOL_IMAGE" \
  bash -c '/work/inner.sh; rc=$?; if [ "$OPEN_SHELL" = 1 ]; then echo "(offline test container; exit to finish)"; bash; fi; exit $rc' \
  2>&1 | tee "$OUT_DIR/container.log"
RC=${PIPESTATUS[0]}
set -e

# ---------------------------------------------------------------------------------------------
# Stage 3: the release tarball in a fresh container of the plain base image (no network)
# ---------------------------------------------------------------------------------------------
TARBALL="$(ls "$OUT_DIR"/package/*.tar.gz 2>/dev/null | head -1 || true)"
if [ "$PACKAGE" = 1 ] && [ -n "$TARBALL" ]; then
  log "stage 3: checking $(basename "$TARBALL") in a fresh $BASE_IMAGE container (--network none, non-root)"
  "$ENGINE" image inspect "$BASE_IMAGE" >/dev/null 2>&1 \
    || "$ENGINE" pull "$BASE_IMAGE" >> "$OUT_DIR/image.log" 2>&1
  # The check scripts from the same source snapshot that was built.
  mkdir -p "$WORK_DIR/check/scripts"
  tar -C "$WORK_DIR/check" -xf "$SRC_TAR" scripts/check-tarball.sh scripts/smoke-test.sh 2>/dev/null \
    || cp "$REPO_ROOT"/scripts/check-tarball.sh "$REPO_ROOT"/scripts/smoke-test.sh "$WORK_DIR/check/scripts/"
  # Decoys at the compiled-in prefix: a moved tree must use its own runtime files and parsers,
  # not those of some other wgvim installed in /opt/wgvim.
  mkdir -p "$WORK_DIR/decoy/lib/wgvim/parser" "$WORK_DIR/decoy/share/wgvim/runtime/doc"
  printf 'not a parser\n' > "$WORK_DIR/decoy/lib/wgvim/parser/c.so"
  chmod -R a+rX "$WORK_DIR/check" "$WORK_DIR/decoy"
  set +e
  "$ENGINE" run --rm --network none --user 1000:1000 -e HOME=/tmp -e LANG=C.UTF-8 \
    -v "$OUT_DIR/package:/pkg:ro,$VOL_OPT" -v "$WORK_DIR/check:/check:ro,$VOL_OPT" \
    -v "$WORK_DIR/decoy:/opt/wgvim:ro,$VOL_OPT" \
    "$BASE_IMAGE" bash /check/scripts/check-tarball.sh "/pkg/$(basename "$TARBALL")" \
    > "$OUT_DIR/check-tarball.log" 2>&1
  CT=$?
  set -e
  if [ "$CT" = 0 ]; then
    printf '%-28s %s\n' "tarball in plain UBI 9" "ok (moved, non-root, decoys ignored; see check-tarball.log)" \
      >> "$OUT_DIR/summary.txt"
  else
    printf '%-28s %s\n' "tarball in plain UBI 9" \
      "FAIL ($(tail -1 "$OUT_DIR/check-tarball.log" | sed 's/^check-tarball: FAIL: *//'); see check-tarball.log)" \
      >> "$OUT_DIR/summary.txt"
    RC=1
  fi
elif [ "$PACKAGE" = 1 ]; then
  printf '%-28s %s\n' "tarball in plain UBI 9" "FAIL (no tarball was made)" >> "$OUT_DIR/summary.txt"
  RC=1
fi

echo
cat "$OUT_DIR/summary.txt" 2>/dev/null || log "no summary was written; see $OUT_DIR/container.log"
echo
log "results: $OUT_DIR"
exit "$RC"
