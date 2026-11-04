#!/usr/bin/env bash
# Build, install and manage the wgvim SELinux policy module (contrib/selinux/).
#
#   scripts/wgvim-selinux.sh <command> [options]
#
# Commands:
#   build        compile wgvim.pp (needs selinux-policy-devel; no root)
#   install      build, install the module, label the wgvim binaries, and put the wgvim_t
#                domain in PERMISSIVE mode (denials are logged, nothing is blocked)
#   denials      show what the policy would have denied (from the audit log) since --since
#                (default: "today"), as AVC messages and as suggested rules
#   enforce      make the wgvim_t domain enforcing (run "denials" first and fix what shows up)
#   permissive   back to permissive mode
#   status       module, mode and binary labels
#   uninstall    remove the module and restore the binaries' default labels
#
# Options:
#   --binary PATH   also label this wgvim binary (default: the installed ones, see wgvim.fc;
#                   a binary in a source tree is not labeled unless given here)
#   --since TIME    for "denials": ausearch start time ("today", "recent", "10:00", ...)
#   -h, --help
#
# Requirements on RHEL 9: selinux-policy-devel (build), policycoreutils (semodule,
# restorecon), policycoreutils-python-utils (semanage), audit (ausearch, for denials).
# install, enforce, permissive and uninstall need root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/contrib/selinux"
DEVEL_MAKEFILE=/usr/share/selinux/devel/Makefile
BINARIES=(/usr/bin/wgvim /usr/local/bin/wgvim /opt/wgvim/bin/wgvim)
EXTRA_BINARY=""
SINCE="today"

die() { echo "wgvim-selinux: $*" >&2; exit 1; }
usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; }
need_root() { [ "$(id -u)" = 0 ] || die "'$1' needs root (try: sudo $0 $1)"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found (install $2)"; }

CMD="${1:-}"
[ -n "$CMD" ] || { usage; exit 2; }
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --binary) EXTRA_BINARY="$(realpath "${2:?}")"; shift 2 ;;
    --since) SINCE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

selinux_on() {
  command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled
}

build() {
  [ -f "$DEVEL_MAKEFILE" ] || die "$DEVEL_MAKEFILE not found (dnf install selinux-policy-devel)"
  BUILD_DIR="$(mktemp -d)"
  cp "$SRC_DIR"/wgvim.te "$SRC_DIR"/wgvim.if "$SRC_DIR"/wgvim.fc "$BUILD_DIR"/
  make -s -C "$BUILD_DIR" -f "$DEVEL_MAKEFILE" wgvim.pp
  cp "$BUILD_DIR/wgvim.pp" "$SRC_DIR/wgvim.pp"
  rm -rf "$BUILD_DIR"
  echo "built $SRC_DIR/wgvim.pp"
}

label() {
  local b
  for b in "${BINARIES[@]}"; do
    [ -e "$b" ] && restorecon -v "$b"
  done
  if [ -n "$EXTRA_BINARY" ]; then
    # A binary outside the paths in wgvim.fc: record a local file-context rule for it.
    semanage fcontext -a -t wgvim_exec_t "$EXTRA_BINARY" 2>/dev/null \
      || semanage fcontext -m -t wgvim_exec_t "$EXTRA_BINARY"
    restorecon -v "$EXTRA_BINARY"
  fi
}

case "$CMD" in
  build)
    build
    ;;
  install)
    need_root install
    selinux_on || die "SELinux is not enabled on this system"
    need semodule policycoreutils
    need semanage policycoreutils-python-utils
    build
    semodule -i "$SRC_DIR/wgvim.pp"
    label
    semanage permissive -a wgvim_t
    echo
    echo "Installed in PERMISSIVE mode: denials are logged but nothing is blocked."
    echo "Use wgvim normally for a while (editing, :terminal, clangd, git, building), then run:"
    echo "  sudo $0 denials"
    echo "If nothing unexpected shows up:"
    echo "  sudo $0 enforce"
    ;;
  denials)
    need ausearch audit
    out="$(ausearch -m AVC,USER_AVC,SELINUX_ERR -ts "$SINCE" 2>/dev/null | grep -E 'wgvim_t|wgvim_exec_t|wgvim_devpts_t' || true)"
    if [ -z "$out" ]; then
      echo "No wgvim denials since $SINCE."
      exit 0
    fi
    echo "$out"
    if command -v audit2allow >/dev/null 2>&1; then
      echo
      echo "# Rules that would allow these (review before adding any to wgvim.te: some denials"
      echo "# are the policy working, e.g. connectto on dbus or ssh_home_t reads):"
      echo "$out" | audit2allow
    fi
    ;;
  enforce)
    need_root enforce
    semanage permissive -d wgvim_t
    echo "wgvim_t is now enforcing."
    ;;
  permissive)
    need_root permissive
    semanage permissive -a wgvim_t
    echo "wgvim_t is now permissive."
    ;;
  status)
    if ! selinux_on; then echo "SELinux: not enabled"; exit 0; fi
    echo "SELinux: $(getenforce)"
    if semodule -l 2>/dev/null | grep -qw wgvim; then
      echo "module: installed"
    else
      echo "module: not installed"
    fi
    if semanage permissive -l 2>/dev/null | grep -qw wgvim_t; then
      echo "wgvim_t: permissive"
    else
      echo "wgvim_t: enforcing (if the module is installed)"
    fi
    for b in "${BINARIES[@]}" ${EXTRA_BINARY:+"$EXTRA_BINARY"}; do
      [ -e "$b" ] && ls -Z "$b"
    done
    true
    ;;
  uninstall)
    need_root uninstall
    semanage permissive -d wgvim_t 2>/dev/null || true
    if [ -n "$EXTRA_BINARY" ]; then
      semanage fcontext -d "$EXTRA_BINARY" 2>/dev/null || true
    fi
    semodule -r wgvim
    for b in "${BINARIES[@]}" ${EXTRA_BINARY:+"$EXTRA_BINARY"}; do
      [ -e "$b" ] && restorecon -v "$b"
    done
    echo "Removed."
    ;;
  *)
    usage
    exit 2
    ;;
esac
