/// wgvim: confine the editor and everything it starts with Landlock (Linux 5.13+).
///
/// Called once, early in main(), before any config or plugin runs. The restriction cannot be
/// lifted afterwards, by this process or by anything it starts (:!, :terminal, jobs, LSP
/// servers). See |wgvim-sandbox| for the policy.
///
/// The system calls are made directly (no liblandlock), and the kernel's Landlock ABI is probed
/// at runtime, so newer protections (TCP, truncate, scoping) are used when the kernel has them
/// and older kernels still get the file system rules.

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nvim/api/private/defs.h"
#include "nvim/api/private/helpers.h"
#include "nvim/arglist_defs.h"
#include "nvim/ascii_defs.h"
#include "nvim/buffer_defs.h"
#include "nvim/fileio.h"
#include "nvim/globals.h"
#include "nvim/log.h"
#include "nvim/memory.h"
#include "nvim/eval/vars.h"
#include "nvim/main.h"
#include "nvim/os/fs.h"
#include "nvim/os/os.h"
#include "nvim/os/landlock.h"
#include "nvim/os/stdpaths_defs.h"
#include "nvim/path.h"
#include "nvim/runtime.h"

#ifdef __linux__
# include <dirent.h>
# include <fcntl.h>
# include <sys/prctl.h>
# include <sys/stat.h>
# include <sys/syscall.h>
# include <unistd.h>
#endif

// Landlock UAPI, defined here so the build does not depend on the age of the kernel headers.
// These values are a stable kernel ABI (include/uapi/linux/landlock.h).
#define LL_CREATE_RULESET_VERSION (1U << 0)
#define LL_RULE_PATH_BENEATH 1

#define LL_FS_EXECUTE (1ULL << 0)
#define LL_FS_WRITE_FILE (1ULL << 1)
#define LL_FS_READ_FILE (1ULL << 2)
#define LL_FS_READ_DIR (1ULL << 3)
#define LL_FS_REMOVE_DIR (1ULL << 4)
#define LL_FS_REMOVE_FILE (1ULL << 5)
#define LL_FS_MAKE_CHAR (1ULL << 6)
#define LL_FS_MAKE_DIR (1ULL << 7)
#define LL_FS_MAKE_REG (1ULL << 8)
#define LL_FS_MAKE_SOCK (1ULL << 9)
#define LL_FS_MAKE_FIFO (1ULL << 10)
#define LL_FS_MAKE_BLOCK (1ULL << 11)
#define LL_FS_MAKE_SYM (1ULL << 12)
#define LL_FS_REFER (1ULL << 13)     // ABI 2
#define LL_FS_TRUNCATE (1ULL << 14)  // ABI 3

#define LL_NET_BIND_TCP (1ULL << 0)     // ABI 4
#define LL_NET_CONNECT_TCP (1ULL << 1)  // ABI 4

#define LL_SCOPE_ABSTRACT_UNIX_SOCKET (1ULL << 0)  // ABI 6

#ifndef SYS_landlock_create_ruleset
# define SYS_landlock_create_ruleset 444
#endif
#ifndef SYS_landlock_add_rule
# define SYS_landlock_add_rule 445
#endif
#ifndef SYS_landlock_restrict_self
# define SYS_landlock_restrict_self 446
#endif

struct ll_ruleset_attr {
  uint64_t handled_access_fs;
  uint64_t handled_access_net;
  uint64_t scoped;
};

struct ll_path_beneath_attr {
  uint64_t allowed_access;
  int32_t parent_fd;
} __attribute__((packed));

// Rights that apply to a file (not a directory) in a rule.
#define LL_FILE_RIGHTS (LL_FS_EXECUTE | LL_FS_WRITE_FILE | LL_FS_READ_FILE | LL_FS_TRUNCATE)

#define R_ACCESS (LL_FS_READ_FILE | LL_FS_READ_DIR)
#define X_ACCESS LL_FS_EXECUTE
#define W_ACCESS (LL_FS_WRITE_FILE | LL_FS_TRUNCATE | LL_FS_REMOVE_DIR | LL_FS_REMOVE_FILE \
                  | LL_FS_MAKE_DIR | LL_FS_MAKE_REG | LL_FS_MAKE_SOCK | LL_FS_MAKE_FIFO \
                  | LL_FS_MAKE_SYM | LL_FS_REFER)
#define DEV_ACCESS (LL_FS_READ_FILE | LL_FS_WRITE_FILE | LL_FS_TRUNCATE | LL_FS_READ_DIR)

#define MAX_RULES 96
#define MAX_NOTES 8

typedef struct {
  char *path;
  const char *access;  // "ro", "rx", "rw", "rwx", "dev"
  bool ok;
  const char *error;   // reason when not ok
} LLRule;

static struct {
  LandlockStatus status;
  int abi;
  const char *reason;  // why not active (static string), or NULL
  bool network;        // TCP bind/connect blocked
  bool scoped;         // abstract Unix sockets outside the sandbox blocked
  LLRule rules[MAX_RULES];
  int nrules;
  char *notes[MAX_NOTES];
  int nnotes;
  char *home;          // realpath of $HOME, for hints
} ll = { .status = kLandlockOff };

#include "os/landlock.c.generated.h"

/// @return [allocated] "dir/name"
static char *join_path(const char *dir, const char *name)
{
  return concat_fnames_realloc(xstrdup(dir), name, true);
}

static void add_note(const char *fmt, const char *arg)
{
  if (ll.nnotes < MAX_NOTES) {
    size_t len = strlen(fmt) + (arg ? strlen(arg) : 0) + 1;
    char *s = xmalloc(len);
    snprintf(s, len, fmt, arg ? arg : "");
    ll.notes[ll.nnotes++] = s;
  }
}

/// @return the sandbox status.
LandlockStatus landlock_status(void)
{
  return ll.status;
}

/// @return true if the sandbox is active.
bool landlock_active(void)
{
  return ll.status == kLandlockActive;
}

/// Whether an open() of `path` that failed with `err` was most likely refused by the sandbox,
/// rather than by file permissions. Landlock does not affect access(2), so if the permission
/// bits allow the access, the refusal came from the sandbox.
///
/// @param path  file that could not be opened
/// @param err   libuv error (negative errno) from the open
/// @param write true if the file was opened for writing
bool landlock_blocked(const char *path, int err, bool write)
{
#ifdef __linux__
  if (!landlock_active() || err != -EACCES || path == NULL) {
    return false;
  }
  int mode = write ? W_OK : R_OK;
  if (access(path, F_OK) == 0) {
    return access(path, mode) == 0;
  }
  // A new file: check the directory it would be created in.
  char *dir = xstrdup(path);
  char *tail = path_tail(dir);
  if (tail == dir) {
    xfree(dir);
    return access(".", W_OK | X_OK) == 0;
  }
  *tail = NUL;
  bool r = access(dir, W_OK | X_OK) == 0;
  xfree(dir);
  return r;
#else
  (void)path; (void)err; (void)write;
  return false;
#endif
}

#ifdef __linux__

static char *real_path(const char *p)
{
  if (p == NULL || *p == NUL) {
    return NULL;
  }
  char *r = realpath(p, NULL);
  if (r == NULL) {
    return NULL;
  }
  char *s = xstrdup(r);
  free(r);  // NOLINT: allocated by realpath()
  return s;
}

/// True if `a` is `b` or inside it (both real paths).
static bool path_within(const char *a, const char *b)
{
  size_t lb = strlen(b);
  if (strcmp(b, "/") == 0) {
    return true;
  }
  return strncmp(a, b, lb) == 0 && (a[lb] == NUL || a[lb] == '/');
}

static uint64_t access_bits(const char *kind)
{
  if (strcmp(kind, "ro") == 0) {
    return R_ACCESS;
  } else if (strcmp(kind, "rx") == 0) {
    return R_ACCESS | X_ACCESS;
  } else if (strcmp(kind, "rw") == 0) {
    return R_ACCESS | W_ACCESS;
  } else if (strcmp(kind, "rwx") == 0) {
    return R_ACCESS | W_ACCESS | X_ACCESS;
  }
  return DEV_ACCESS;  // "dev"
}

/// Adds a rule for `path` (which need not exist; missing paths are skipped quietly unless
/// `report_missing`).
static void add_rule(int ruleset_fd, uint64_t handled, const char *path, const char *kind,
                     bool report_missing)
{
  if (path == NULL || *path == NUL || ll.nrules >= MAX_RULES) {
    return;
  }
  for (int i = 0; i < ll.nrules; i++) {
    if (strcmp(ll.rules[i].path, path) == 0 && strcmp(ll.rules[i].access, kind) == 0) {
      return;  // duplicate
    }
  }
  int fd = open(path, O_PATH | O_CLOEXEC);
  if (fd < 0) {
    if (report_missing) {
      ll.rules[ll.nrules++] = (LLRule){ xstrdup(path), kind, false, "not found" };
    }
    return;
  }
  struct stat st;
  uint64_t allowed = access_bits(kind) & handled;
  if (fstat(fd, &st) == 0 && !S_ISDIR(st.st_mode)) {
    allowed &= LL_FILE_RIGHTS;
  }
  struct ll_path_beneath_attr pb = { .allowed_access = allowed, .parent_fd = fd };
  bool ok = syscall(SYS_landlock_add_rule, ruleset_fd, LL_RULE_PATH_BENEATH, &pb, 0) == 0;
  int e = errno;
  close(fd);
  ll.rules[ll.nrules++] = (LLRule){ xstrdup(path), kind, ok, ok ? NULL : strerror(e) };
}

/// Adds a rule for `$HOME/<sub>` if it exists.
static void add_home_rule(int rfd, uint64_t handled, const char *sub, const char *kind)
{
  if (ll.home == NULL) {
    return;
  }
  char *p = join_path(ll.home, sub);
  add_rule(rfd, handled, p, kind, false);
  xfree(p);
}

/// Grants `kind` on a directory the user is working in (the current directory, or a directory
/// named on the command line). Refuses the file system root and $HOME's ancestors, and for
/// $HOME itself grants only the entries that are not hidden, so that ~/.ssh, ~/.gnupg and
/// dotfiles stay out of reach.
static void add_work_dir(int rfd, uint64_t handled, const char *dir, const char *what)
{
  char *real = real_path(dir);
  if (real == NULL) {
    return;
  }
  if (ll.home != NULL && path_within(ll.home, real) && strcmp(real, ll.home) != 0) {
    add_note("%s is the root or an ancestor of your home directory; it is not writable "
             "(start wgvim inside a project directory)", what);
  } else if (strcmp(real, "/") == 0) {
    add_note("%s is /; it is not writable (start wgvim inside a project directory)", what);
  } else if (ll.home != NULL && strcmp(real, ll.home) == 0) {
    add_note("%s is your home directory: only its non-hidden entries are writable", what);
    DIR *d = opendir(real);
    if (d != NULL) {
      struct dirent *e;
      while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') {
          continue;
        }
        char *p = join_path(real, e->d_name);
        add_rule(rfd, handled, p, "rwx", false);
        xfree(p);
      }
      closedir(d);
    }
  } else {
    add_rule(rfd, handled, real, "rwx", true);
  }
  xfree(real);
}

static void add_xdg_dirs(int rfd, uint64_t handled, XDGVarType var)
{
  char *dirs = stdpaths_get_xdg_var(var);
  if (dirs == NULL) {
    return;
  }
  for (char *p = strtok(dirs, ":"); p != NULL; p = strtok(NULL, ":")) {
    add_rule(rfd, handled, p, "ro", false);
  }
  xfree(dirs);
}

static char *mkdir_get(char *path)
{
  if (path != NULL) {
    char *failed = NULL;
    (void)os_mkdir_recurse(path, 0700, &failed, NULL);
    xfree(failed);
  }
  return path;
}

#endif  // __linux__

/// Applies the sandbox. Exits with an error if `mode` is "require" and it cannot be applied.
///
/// @param mode      "on", "off", "require", or NULL for $WGVIM_SANDBOX (default "on")
/// @param allow_rw  extra read-write paths (--sandbox-allow)
/// @param allow_ro  extra read-only paths (--sandbox-allow-ro)
void landlock_init(const char *mode, char **allow_rw, int n_rw, char **allow_ro, int n_ro)
{
  if (mode == NULL) {
    mode = os_getenv_noalloc("WGVIM_SANDBOX");
  }
  if (mode == NULL || *mode == NUL) {
    mode = "on";
  }
  bool require = strequal(mode, "require");
  if (strequal(mode, "off")) {
    ll.status = kLandlockOff;
    ll.reason = "turned off (--sandbox off or $WGVIM_SANDBOX=off)";
    return;
  } else if (!require && !strequal(mode, "on")) {
    fprintf(stderr, "wgvim: --sandbox must be on, off or require (got \"%s\")\n", mode);
    os_exit(2);
  }

#ifndef __linux__
  ll.status = kLandlockUnavailable;
  ll.reason = "Landlock is only available on Linux";
#else
  int abi = (int)syscall(SYS_landlock_create_ruleset, NULL, 0, LL_CREATE_RULESET_VERSION);
  if (abi < 0) {
    ll.status = kLandlockUnavailable;
    ll.reason = errno == EOPNOTSUPP ? "Landlock is disabled in this kernel (boot option lsm=)"
                                    : "this kernel has no Landlock (needs Linux 5.13+ "
                                      "or RHEL 9.6+)";
    goto done;
  }
  ll.abi = abi;

  uint64_t handled = LL_FS_EXECUTE | LL_FS_WRITE_FILE | LL_FS_READ_FILE | LL_FS_READ_DIR
                     | LL_FS_REMOVE_DIR | LL_FS_REMOVE_FILE | LL_FS_MAKE_CHAR | LL_FS_MAKE_DIR
                     | LL_FS_MAKE_REG | LL_FS_MAKE_SOCK | LL_FS_MAKE_FIFO | LL_FS_MAKE_BLOCK
                     | LL_FS_MAKE_SYM;
  if (abi >= 2) {
    handled |= LL_FS_REFER;
  }
  if (abi >= 3) {
    handled |= LL_FS_TRUNCATE;
  }
  struct ll_ruleset_attr attr = { .handled_access_fs = handled };
  size_t attr_size = sizeof(uint64_t);
  if (abi >= 4) {
    attr.handled_access_net = LL_NET_BIND_TCP | LL_NET_CONNECT_TCP;  // and no rule allows any
    attr_size = 2 * sizeof(uint64_t);
    ll.network = true;
  }
  if (abi >= 6) {
    attr.scoped = LL_SCOPE_ABSTRACT_UNIX_SOCKET;
    attr_size = sizeof(attr);
    ll.scoped = true;
  }
  int rfd = (int)syscall(SYS_landlock_create_ruleset, &attr, attr_size, 0);
  if (rfd < 0) {
    ll.status = kLandlockFailed;
    ll.reason = "landlock_create_ruleset() failed";
    ll.network = ll.scoped = false;
    goto done;
  }

  const char *home_env = os_homedir();
  ll.home = real_path(home_env);

  // System: programs, libraries, headers, configuration, kernel interfaces.
  static const char *const sys_rx[] = { "/usr", "/bin", "/sbin", "/lib", "/lib64", "/opt" };
  for (size_t i = 0; i < ARRAY_SIZE(sys_rx); i++) {
    add_rule(rfd, handled, sys_rx[i], "rx", false);
  }
  static const char *const sys_ro[] = { "/etc", "/proc", "/sys", "/var/lib/sss",
                                        "/dev/urandom", "/dev/random" };
  for (size_t i = 0; i < ARRAY_SIZE(sys_ro); i++) {
    add_rule(rfd, handled, sys_ro[i], "ro", false);
  }
  // Terminals: our own, and new ones for :terminal (/dev/ptmx, /dev/pts/N).
  static const char *const devs[] = { "/dev/null", "/dev/zero", "/dev/full", "/dev/tty",
                                      "/dev/ptmx", "/dev/pts" };
  for (size_t i = 0; i < ARRAY_SIZE(devs); i++) {
    add_rule(rfd, handled, devs[i], "dev", false);
  }
  for (int fd = 0; fd <= 2; fd++) {
    char *tty = isatty(fd) ? ttyname(fd) : NULL;
    if (tty != NULL) {
      add_rule(rfd, handled, tty, "dev", false);
    }
  }

  // wgvim itself: the executable (the TUI starts it again as the server), $VIMRUNTIME, parsers.
  const char *progpath = get_vim_var_str(VV_PROGPATH);
  if (progpath != NULL && *progpath != NUL) {
    char *dir = real_path(progpath);
    if (dir != NULL) {
      *path_tail(dir) = NUL;
      add_rule(rfd, handled, dir, "rx", false);
      xfree(dir);
    }
  }
  char *vimruntime = vim_getenv("VIMRUNTIME");
  add_rule(rfd, handled, vimruntime, "ro", false);
  xfree(vimruntime);
  char *libdir = get_lib_dir();
  add_rule(rfd, handled, libdir, "ro", false);
  xfree(libdir);

  // Config and installed plugins: read-only. State, cache and temp: read-write.
  char *p = stdpaths_user_conf_subpath("");
  add_rule(rfd, handled, p, "ro", false);
  xfree(p);
  add_xdg_dirs(rfd, handled, kXDGConfigDirs);
  p = stdpaths_user_data_subpath("");
  add_rule(rfd, handled, p, "ro", false);
  xfree(p);
  add_xdg_dirs(rfd, handled, kXDGDataDirs);
  p = mkdir_get(stdpaths_user_state_subpath("", 0, false));
  add_rule(rfd, handled, p, "rw", true);
  xfree(p);
  p = mkdir_get(stdpaths_user_cache_subpath(""));
  add_rule(rfd, handled, p, "rw", true);
  xfree(p);
  const char *logfile = os_getenv_noalloc("WGVIM_LOG_FILE");
  if (logfile != NULL && *logfile != NUL) {
    FILE *f = fopen(logfile, "a");
    if (f != NULL) {
      fclose(f);
    }
    add_rule(rfd, handled, logfile, "rw", false);
  }
  // The temp root ("/tmp/wgvim.<user>/"): this process's temp dir is created in it, and so are
  // those of child processes, which get it as $TMPDIR below.
  char *temp_root = NULL;
  char *tempdir = vim_gettempdir();
  if (tempdir != NULL) {
    temp_root = xstrdup(tempdir);
    char *end = temp_root + strlen(temp_root);
    while (end > temp_root + 1 && end[-1] == '/') {
      *--end = NUL;
    }
    *path_tail(temp_root) = NUL;
    add_rule(rfd, handled, temp_root, "rw", true);
  }

  // Dotfiles that :! and :terminal shells, git and clangd read; private tool directories.
  static const char *const home_ro[] = { ".bashrc", ".bash_profile", ".bash_logout", ".profile",
                                         ".inputrc", ".gitconfig", ".config/git",
                                         ".config/clangd", ".clang-format", ".clang-tidy",
                                         ".editorconfig" };
  for (size_t i = 0; i < ARRAY_SIZE(home_ro); i++) {
    add_home_rule(rfd, handled, home_ro[i], "ro");
  }
  add_home_rule(rfd, handled, ".local/bin", "rx");
  add_home_rule(rfd, handled, "bin", "rx");
  // clangd keeps an index for files outside a project in ~/.cache/clangd.
  if (os_can_exe("clangd", NULL, true) && ll.home != NULL) {
    char *cd = join_path(ll.home, ".cache/clangd");
    xfree(mkdir_get(cd));
    add_home_rule(rfd, handled, ".cache/clangd", "rw");
  }

  // The work: the current directory tree, and what was named on the command line.
  char cwd[MAXPATHL];
  if (os_dirname(cwd, sizeof(cwd)) == OK) {
    add_work_dir(rfd, handled, cwd, "the current directory");
  }
  for (int i = 0; i < GARGCOUNT; i++) {
    char *name = GARGLIST[i].ae_fname;
    char *real = real_path(name);
    if (real == NULL) {
      // A new file. Inside the current directory it can be created; elsewhere it cannot.
      continue;
    }
    if (os_isdir(real)) {
      add_work_dir(rfd, handled, real, name);
    } else {
      add_rule(rfd, handled, real, "rw", true);  // this file only
    }
    xfree(real);
  }
  for (int i = 0; i < n_rw; i++) {
    add_rule(rfd, handled, allow_rw[i], "rwx", true);
  }
  for (int i = 0; i < n_ro; i++) {
    add_rule(rfd, handled, allow_ro[i], "rx", true);
  }

  // From here on, setuid programs (sudo, su) cannot gain privileges; Landlock requires this.
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
      || syscall(SYS_landlock_restrict_self, rfd, 0) != 0) {
    ll.status = kLandlockFailed;
    ll.reason = "landlock_restrict_self() failed";
    ll.network = ll.scoped = false;
    close(rfd);
    xfree(temp_root);
    goto done;
  }
  close(rfd);
  ll.status = kLandlockActive;
  if (temp_root != NULL) {
    os_setenv("TMPDIR", temp_root, 1);  // child programs: compilers, clangd preambles, ...
    xfree(temp_root);
  }
  ILOG("sandbox active: Landlock ABI %d, %d rules", abi, ll.nrules);
#endif

done:
  if (ll.status != kLandlockActive) {
    if (require) {
      fprintf(stderr, "wgvim: --sandbox require: the sandbox could not be applied: %s\n",
              ll.reason);
      os_exit(1);
    }
    WLOG("sandbox not active: %s", ll.reason);
  }
}

/// Information for :checkhealth and tests (|nvim__sandbox_info()|).
Dict landlock_info(Arena *arena)
{
  static const char *const names[] = { "off", "active", "unavailable", "failed" };
  Dict rv = arena_dict(arena, 8);
  PUT_C(rv, "status", CSTR_AS_OBJ(names[ll.status]));
  PUT_C(rv, "abi", INTEGER_OBJ(ll.abi));
  PUT_C(rv, "reason", CSTR_AS_OBJ(ll.reason ? ll.reason : ""));
  PUT_C(rv, "network", BOOLEAN_OBJ(ll.network));
  PUT_C(rv, "scoped", BOOLEAN_OBJ(ll.scoped));
  Array rules = arena_array(arena, (size_t)ll.nrules);
  for (int i = 0; i < ll.nrules; i++) {
    Dict r = arena_dict(arena, 4);
    PUT_C(r, "path", CSTR_AS_OBJ(ll.rules[i].path));
    PUT_C(r, "access", CSTR_AS_OBJ(ll.rules[i].access));
    PUT_C(r, "ok", BOOLEAN_OBJ(ll.rules[i].ok));
    PUT_C(r, "error", CSTR_AS_OBJ(ll.rules[i].error ? ll.rules[i].error : ""));
    ADD_C(rules, DICT_OBJ(r));
  }
  PUT_C(rv, "rules", ARRAY_OBJ(rules));
  Array notes = arena_array(arena, (size_t)ll.nnotes);
  for (int i = 0; i < ll.nnotes; i++) {
    ADD_C(notes, CSTR_AS_OBJ(ll.notes[i]));
  }
  PUT_C(rv, "notes", ARRAY_OBJ(notes));
  return rv;
}
