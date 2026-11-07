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
#include "nvim/charset.h"
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
#include "nvim/sha256.h"

#ifdef __linux__
# include <dirent.h>
# include <strings.h>
# include <fcntl.h>
# include <linux/audit.h>
# include <linux/filter.h>
# include <linux/seccomp.h>
# include <stddef.h>
# include <sys/ioctl.h>
# include <sys/prctl.h>
# include <poll.h>
# include <spawn.h>
# include <signal.h>
# include <sys/socket.h>
# include <sys/wait.h>
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
#define LL_SCOPE_SIGNAL (1ULL << 1)                // ABI 6

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

// A file of the .git watch (|wgvim-sandbox-git|), and a record of them.
#define GIT_MAX_FILES 1024
typedef struct {
  char *path;                       // absolute
  uint8_t digest[SHA256_SUM_SIZE];  // file type and mode, and contents or symlink target
  char *text;                       // a config file's contents, for the report; or NULL
} GitFile;

typedef struct {
  GitFile f[GIT_MAX_FILES];
  int n;
} GitSnap;


static struct {
  LandlockStatus status;
  int abi;
  const char *reason;  // why not active (static string), or NULL
  bool network;        // TCP bind/connect blocked
  bool scoped;         // abstract Unix sockets and signals outside the sandbox blocked
  bool seccomp;        // the system call filter is installed
  bool connect;        // connect() is allowed (the TUI process, to wgvim's own sockets only)
  char *temp_root;     // wgvim's temp root, where its own sockets live
  int clip_fd;         // socket to the clipboard helper, or -1
  const char *clip_tool;  // "wl-clipboard", "xclip", "xsel", or NULL
  LLRule rules[MAX_RULES];
  int nrules;
  char *notes[MAX_NOTES];
  int nnotes;
  char *home;          // realpath of $HOME, for hints
} ll = { .status = kLandlockOff, .clip_fd = -1 };

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

/// Number of components in an absolute real path: "/" is 0, "/home" is 1.
static int path_depth(const char *p)
{
  int n = 0;
  for (; *p; p++) {
    if (*p == '/' && p[1] != NUL && p[1] != '/') {
      n++;
    }
  }
  return n;
}

/// Grants access to a directory the user is working in (the current directory, or a directory
/// named on the command line). Refuses "/" and top-level directories that contain $HOME (such
/// as "/home"), and for $HOME itself grants only the entries that are not hidden, so that
/// ~/.ssh, ~/.gnupg and dotfiles stay out of reach.
static void add_work_dir(int rfd, uint64_t handled, const char *dir, const char *what)
{
  char *real = real_path(dir);
  if (real == NULL) {
    return;
  }
  bool contains_home = ll.home != NULL && path_within(ll.home, real);
  if (strcmp(real, "/") == 0 || (contains_home && strcmp(real, ll.home) != 0
                                 && path_depth(real) <= 1)) {
    add_note("%s contains home directories; it is not writable (start wgvim inside a "
             "project directory)", what);
  } else if (contains_home && strcmp(real, ll.home) == 0) {
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
    if (contains_home) {
      add_note("your home directory is inside %s, so it is reachable too", what);
    }
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
    int r = os_mkdir_recurse(path, 0700, &failed, NULL);
    if (r != 0) {
      // Not fatal: the rule for the directory is then skipped (and reported).
      WLOG("sandbox: cannot create %s: %s", failed ? failed : path, os_strerror(r));
    }
    xfree(failed);
  }
  return path;
}

#endif  // __linux__

#ifdef __linux__

# if defined(__x86_64__)
#  define SC_ARCH AUDIT_ARCH_X86_64
# elif defined(__aarch64__)
#  define SC_ARCH AUDIT_ARCH_AARCH64
# endif

# define SC_ALLOW BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)
# define SC_ERRNO(e) BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ((e) & SECCOMP_RET_DATA))
# define SC_LOAD(field) BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, field))
// If the syscall number is `nr`, return errno `e`; else fall through.
# define SC_DENY(nr, e) BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (nr), 0, 1), SC_ERRNO(e)
// The clone() and unshare() flags that make new namespaces: NEWNS, NEWCGROUP, NEWUTS, NEWIPC,
// NEWUSER, NEWPID, NEWNET. CLONE_NEWTIME (0x80) is added for unshare() only: in clone() that bit
// is part of the exit signal, and clone3(), which takes it, is refused.
# define SC_CLONE_NEW (0x00020000u | 0x02000000u | 0x04000000u | 0x08000000u | 0x10000000u \
                       | 0x20000000u | 0x40000000u)
# define SC_CLONE_NEWTIME 0x00000080u

static bool install_filter(struct sock_filter *f, size_t n)
{
  struct sock_fprog prog = { .len = (unsigned short)n, .filter = f };
  return prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0
         && prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) == 0;
}

/// Mode from "--sandbox {mode}" in argv, else $WGVIM_SANDBOX, else "on".
static const char *early_mode(int argc, char **argv)
{
  for (int i = 1; i + 1 < argc; i++) {
    if (strcmp(argv[i], "--sandbox") == 0) {
      return argv[i + 1];
    } else if (strcmp(argv[i], "--") == 0 || strcmp(argv[i], "-l") == 0) {
      break;
    }
  }
  const char *env = getenv("WGVIM_SANDBOX");
  return env != NULL && *env != NUL ? env : "on";
}

#endif  // __linux__

/// Called first thing in main(), before the event loop exists: when the sandbox will be on,
/// refuses io_uring from here on, so that libuv uses epoll and no io_uring ring exists that
/// could be used to open sockets without going through the system call filter.
void landlock_early(int argc, char **argv)
{
#if defined(__linux__) && defined(SC_ARCH) && defined(__NR_io_uring_setup)
  if (strcmp(early_mode(argc, argv), "off") == 0) {
    return;
  }
  struct sock_filter f[] = {
    SC_LOAD(arch),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SC_ARCH, 1, 0),
    SC_ALLOW,  // a foreign ABI is handled by the full filter later
    SC_LOAD(nr),
    SC_DENY(__NR_io_uring_setup, ENOSYS),
    SC_ALLOW,
  };
  (void)install_filter(f, ARRAY_SIZE(f));
#else
  (void)argc; (void)argv;
#endif
}

#ifdef __linux__
/// The system call filter (seccomp), inherited like the Landlock rules:
/// - sockets: only Unix (no UDP, ICMP, raw, packet, netlink, ...);
/// - connect() refused unless `allow_connect` (Landlock does not control connecting to existing
///   Unix sockets such as the D-Bus bus, ssh-agent or gpg-agent); sendto() with an address too;
/// - System V IPC refused; io_uring refused (it can open sockets past this filter);
/// - other ABIs (x32, i386) refused.
static bool install_seccomp(bool allow_connect)
{
# ifndef SC_ARCH
  (void)allow_connect;
  return false;
# else
  struct sock_filter f[] = {
    SC_LOAD(arch),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SC_ARCH, 1, 0),
    SC_ERRNO(ENOSYS),
    SC_LOAD(nr),
#  ifdef __x86_64__
    BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000, 0, 1),  // x32 ABI
    SC_ERRNO(ENOSYS),
#  endif
    // socket(domain, ...): only AF_UNIX.
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socket, 0, 4),
    SC_LOAD(args[0]),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_UNIX, 0, 1),
    SC_ALLOW,
    SC_ERRNO(EAFNOSUPPORT),
    // connect(): refused, or allowed for the TUI process (checked against the temp root in C).
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_connect, 0, 1),
    BPF_STMT(BPF_RET | BPF_K,
             allow_connect ? SECCOMP_RET_ALLOW : (SECCOMP_RET_ERRNO | (EACCES & SECCOMP_RET_DATA))),
    // sendto(fd, buf, len, flags, dest_addr, addrlen): refused when dest_addr is given.
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_sendto, 0, 6),
    SC_LOAD(args[4]),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 0, 3),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[4]) + 4),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 0, 1),
    SC_ALLOW,
    SC_ERRNO(EACCES),
    SC_LOAD(nr),  // reload after the sendto branch
    // ioctl(fd, request): not TIOCSTI or TIOCLINUX, which push characters into a terminal's
    // input: into the shell that started wgvim, to run once wgvim exits. The kernel takes the
    // request as an unsigned int, so only the low 32 bits are compared (bits set above them
    // must not get it past the check).
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_ioctl, 0, 5),
    SC_LOAD(args[1]),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, TIOCSTI, 2, 0),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, TIOCLINUX, 1, 0),
    SC_ALLOW,
    SC_ERRNO(EPERM),
    // clone(flags, ...) and unshare(flags): no new namespaces. A user namespace grants
    // capabilities inside it, and with them much more of the kernel to attack (Landlock and this
    // filter still apply inside it). Processes and threads, which set none of these flags, pass.
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone, 0, 4),
    SC_LOAD(args[0]),
    BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, SC_CLONE_NEW, 1, 0),
    SC_ALLOW,
    SC_ERRNO(EPERM),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_unshare, 0, 4),
    SC_LOAD(args[0]),
    BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, SC_CLONE_NEW | SC_CLONE_NEWTIME, 1, 0),
    SC_ALLOW,
    SC_ERRNO(EPERM),
    // clone3() passes its flags in memory, which a filter cannot read. ENOSYS makes the C library
    // (glibc 2.34+, musl) and the Go and Rust runtimes fall back to clone(), checked above.
    SC_DENY(__NR_clone3, ENOSYS),
    SC_DENY(__NR_setns, EPERM),
    // Kernel keyrings (Kerberos tickets, keys, ...) are not files, so Landlock does not cover them.
    SC_DENY(__NR_keyctl, EPERM),
    SC_DENY(__NR_add_key, EPERM),
    SC_DENY(__NR_request_key, EPERM),
    SC_DENY(__NR_io_uring_setup, ENOSYS),
    SC_DENY(__NR_io_uring_enter, ENOSYS),
    SC_DENY(__NR_io_uring_register, ENOSYS),
    SC_DENY(__NR_shmget, EPERM),
    SC_DENY(__NR_shmat, EPERM),
    SC_DENY(__NR_shmctl, EPERM),
    SC_DENY(__NR_shmdt, EPERM),
    SC_DENY(__NR_semget, EPERM),
    SC_DENY(__NR_semop, EPERM),
    SC_DENY(__NR_semtimedop, EPERM),
    SC_DENY(__NR_semctl, EPERM),
    SC_DENY(__NR_msgget, EPERM),
    SC_DENY(__NR_msgsnd, EPERM),
    SC_DENY(__NR_msgrcv, EPERM),
    SC_DENY(__NR_msgctl, EPERM),
    SC_ALLOW,
  };
  return install_filter(f, ARRAY_SIZE(f));
# endif
}

static int count_threads(void)
{
  DIR *d = opendir("/proc/self/task");
  int n = 0;
  struct dirent *e;
  while (d != NULL && (e = readdir(d)) != NULL) {
    n += e->d_name[0] != '.';
  }
  if (d != NULL) {
    closedir(d);
  }
  return n;
}
#endif


#ifdef __linux__
// The clipboard helper.
//
// Clipboard tools (wl-copy, xclip, xsel) must connect to the display server, which the sandbox
// refuses. Before the sandbox is applied, the editor process forks this helper. It keeps the
// right to connect and does one thing: for a request "copy" or "paste" of register + or *, it
// runs the fixed command for the tool it chose at startup, with the bytes it was given, and
// returns the result. It reads nothing else from the editor, so a compromised editor can only
// read and write the clipboard, which the clipboard feature allows anyway.
//
// Request: op ('c' or 'p'), reg ('+' or '*'), uint32 length, data. Reply: uint32 length, data;
// length 0xFFFFFFFF means failure.

extern char **environ;

# define CLIP_MAX (64u * 1024 * 1024)
# define CLIP_FAIL 0xFFFFFFFFu

static bool full_io(int fd, void *buf, size_t len, bool rd)
{
  char *p = buf;
  while (len > 0) {
    ssize_t n = rd ? read(fd, p, len) : write(fd, p, len);
    if (n < 0 && errno == EINTR) {
      continue;
    }
    if (n <= 0) {
      return false;
    }
    p += n;
    len -= (size_t)n;
  }
  return true;
}

static const char **clip_argv(const char *tool, bool paste, bool primary)
{
  static const char *wl_c[] = { "wl-copy", "--type", "text/plain", NULL };
  static const char *wl_cp[] = { "wl-copy", "--primary", "--type", "text/plain", NULL };
  static const char *wl_p[] = { "wl-paste", "--no-newline", NULL };
  static const char *wl_pp[] = { "wl-paste", "--no-newline", "--primary", NULL };
  static const char *xc_c[] = { "xclip", "-i", "-selection", "clipboard", NULL };
  static const char *xc_cp[] = { "xclip", "-i", "-selection", "primary", NULL };
  static const char *xc_p[] = { "xclip", "-o", "-selection", "clipboard", NULL };
  static const char *xc_pp[] = { "xclip", "-o", "-selection", "primary", NULL };
  static const char *xs_c[] = { "xsel", "-i", "-b", NULL };
  static const char *xs_cp[] = { "xsel", "-i", "-p", NULL };
  static const char *xs_p[] = { "xsel", "-o", "-b", NULL };
  static const char *xs_pp[] = { "xsel", "-o", "-p", NULL };
  if (strcmp(tool, "wl-clipboard") == 0) {
    return paste ? (primary ? wl_pp : wl_p) : (primary ? wl_cp : wl_c);
  } else if (strcmp(tool, "xclip") == 0) {
    return paste ? (primary ? xc_pp : xc_p) : (primary ? xc_cp : xc_c);
  }
  return paste ? (primary ? xs_pp : xs_p) : (primary ? xs_cp : xs_c);
}

// Absolute paths of the copy and paste programs, resolved once before the sandbox is applied.
static char *clip_copy_prog = NULL;
static char *clip_paste_prog = NULL;

/// Runs `prog` with argv (argv[0] is only its name) and `in` on its stdin; collects stdout into
/// *out (malloc'd) for paste.
static bool clip_run(const char *prog, const char **argv, const char *in, size_t in_len,
                     char **out, size_t *out_len)
{
  int ip[2], op[2];
  if (pipe2(ip, O_CLOEXEC) != 0) {
    return false;
  }
  if (pipe2(op, O_CLOEXEC) != 0) {
    close(ip[0]);
    close(ip[1]);
    return false;
  }
  // posix_spawn, not fork(): fork handlers registered in the editor (pthread_atfork) would run
  // in the child and reuse file descriptor numbers that belong to these pipes.
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, ip[0], 0);
  posix_spawn_file_actions_adddup2(&fa, op[1], 1);
  posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addclose(&fa, ip[1]);
  posix_spawn_file_actions_addclose(&fa, op[0]);
  pid_t pid;
  // posix_spawn with the path resolved at startup, not posix_spawnp: a $PATH lookup now could
  // find a program planted since then in a directory the sandbox can write to.
  int rc = posix_spawn(&pid, prog, &fa, NULL, (char **)argv, environ);
  posix_spawn_file_actions_destroy(&fa);
  if (rc != 0) {
    close(ip[0]); close(ip[1]); close(op[0]); close(op[1]);
    return false;
  }
  close(ip[0]);
  close(op[1]);
  bool ok = in_len == 0 || full_io(ip[1], (void *)in, in_len, false);
  close(ip[1]);
  size_t cap = 0, len = 0;
  char *buf = NULL;
  if (out != NULL) {
    struct pollfd pfd = { .fd = op[0], .events = POLLIN };
    while (ok && poll(&pfd, 1, 5000) > 0) {
      if (len == cap) {
        cap = cap ? cap * 2 : 4096;
        if (cap > CLIP_MAX) {
          ok = false;
          break;
        }
        char *nb = realloc(buf, cap);  // NOLINT: the helper does not use xmalloc
        if (nb == NULL) {
          ok = false;
          break;
        }
        buf = nb;
      }
      ssize_t n = read(op[0], buf + len, cap - len);
      if (n < 0 && errno == EINTR) {
        continue;
      }
      if (n <= 0) {
        break;
      }
      len += (size_t)n;
    }
  }
  close(op[0]);
  int status = 0;
  // wl-copy, xclip -i and xsel -i fork to keep serving the selection; the first process exits.
  for (int i = 0; i < 100 && waitpid(pid, &status, WNOHANG) == 0; i++) {
    usleep(50000);
  }
  if (out != NULL) {
    *out = buf;
    *out_len = len;
  } else {
    free(buf);  // NOLINT
  }
  return ok && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static void clip_helper_main(int fd, const char *tool)
  FUNC_ATTR_NORETURN
{
  for (;;) {
    unsigned char hdr[6];
    if (!full_io(fd, hdr, sizeof(hdr), true)) {
      _exit(0);  // the editor exited
    }
    uint32_t len;
    memcpy(&len, hdr + 2, 4);
    bool paste = hdr[0] == 'p';
    bool primary = hdr[1] == '*';
    if ((hdr[0] != 'c' && hdr[0] != 'p') || len > CLIP_MAX) {
      _exit(1);
    }
    char *data = malloc(len + 1);  // NOLINT
    if (data == NULL || !full_io(fd, data, len, true)) {
      _exit(1);
    }
    char *out = NULL;
    size_t out_len = 0;
    bool ok = clip_run(paste ? clip_paste_prog : clip_copy_prog, clip_argv(tool, paste, primary),
                       paste ? NULL : data, paste ? 0 : len, paste ? &out : NULL, &out_len);
    free(data);  // NOLINT
    uint32_t rlen = ok ? (uint32_t)out_len : CLIP_FAIL;
    if (!full_io(fd, &rlen, 4, false) || (ok && out_len && !full_io(fd, out, out_len, false))) {
      _exit(1);
    }
    free(out);  // NOLINT
  }
}

/// The path of the read-write rule that `real` (a realpath) is in or under, or NULL: a place
/// sandboxed processes can write to.
static const char *writable_rule(const char *real)
{
  for (int i = 0; i < ll.nrules; i++) {
    const char *k = ll.rules[i].access;
    if (strcmp(k, "rw") != 0 && strcmp(k, "rwx") != 0) {
      continue;
    }
    char *r = real_path(ll.rules[i].path);
    bool inside = r != NULL && path_within(real, r);
    xfree(r);
    if (inside) {
      return ll.rules[i].path;
    }
  }
  return NULL;
}

/// The absolute path of clipboard program `name`, or NULL. The helper runs it outside the
/// sandbox, so it must not be in a directory that sandboxed processes can write to (the project,
/// the temp root, stdpath() "state" and "cache", --sandbox-allow paths, ...): a program planted
/// there, e.g. in a project directory that is in $PATH, would otherwise run unconfined.
static char *clip_tool_path(const char *name)
{
  char *abs = NULL;
  if (!os_can_exe(name, &abs, true) || abs == NULL) {
    xfree(abs);
    return NULL;
  }
  char *real = real_path(abs);
  xfree(abs);
  if (real == NULL) {
    return NULL;
  }
  const char *rule = writable_rule(real);
  if (rule != NULL) {
    WLOG("sandbox: not using %s for the clipboard: it is in a writable directory (%s)", real,
         rule);
    xfree(real);
    return NULL;
  }
  return real;
}

/// Chooses the clipboard programs: `copy` and `paste` names; both must be usable.
static bool clip_choose(const char *copy, const char *paste)
{
  char *c = clip_tool_path(copy);
  char *p = c != NULL ? clip_tool_path(paste) : NULL;
  if (c == NULL || p == NULL) {
    xfree(c);
    xfree(p);
    return false;
  }
  clip_copy_prog = c;
  clip_paste_prog = p;
  return true;
}

/// Starts the clipboard helper, if there is a local display and a clipboard tool.
static void start_clipboard_helper(void)
{
  if (getenv("SSH_TTY") != NULL || getenv("SSH_CONNECTION") != NULL) {
    return;  // remote: these tools would not reach the user's desktop; OSC 52 is used instead
  }
  const char *wl = getenv("WAYLAND_DISPLAY");
  const char *x = getenv("DISPLAY");
  const char *tool = NULL;
  if (wl != NULL && *wl != NUL && clip_choose("wl-copy", "wl-paste")) {
    tool = "wl-clipboard";
  } else if (x != NULL && *x != NUL && clip_choose("xclip", "xclip")) {
    tool = "xclip";
  } else if (x != NULL && *x != NUL && clip_choose("xsel", "xsel")) {
    tool = "xsel";
  }
  if (tool == NULL) {
    return;
  }
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0) {
    return;
  }
  pid_t pid = fork();
  if (pid < 0) {
    close(sv[0]);
    close(sv[1]);
    return;
  }
  if (pid == 0) {
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    // Not in the project: the clipboard programs then never see it as their working directory.
    if (chdir("/") != 0) {
      _exit(1);
    }
    // Drop the editor's signal handlers: libuv's would write into its signal pipe's file
    // descriptor number, which here belongs to a clipboard tool's pipe.
    for (int sig = 1; sig < NSIG; sig++) {
      signal(sig, SIG_DFL);
    }
    signal(SIGPIPE, SIG_IGN);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    int null = open("/dev/null", O_RDWR);
    for (int i = 0; i <= 2; i++) {
      dup2(null, i);
    }
    dup2(sv[1], 3);
    // Close everything else the editor had open (event loop, terminal, ...).
    for (int i = 4; i < 1024; i++) {
      close(i);
    }
    // The helper may connect (that is its purpose), but still gets the rest of the filter.
    (void)install_seccomp(true);
    clip_helper_main(3, tool);
  }
  close(sv[1]);
  ll.clip_fd = sv[0];
  ll.clip_tool = tool;
}

# define CLIP_ENV "WGVIM_CLIPBOARD_FD"

/// With a terminal UI, the editor process is started by the UI process, which is already
/// confined by then, and so would be a helper the editor forked. So the UI process forks the
/// helper and passes its socket to the editor process: inherited, named in $WGVIM_CLIPBOARD_FD.
static void pass_clipboard_helper(void)
{
  if (ll.clip_fd < 0) {
    return;
  }
  int flags = fcntl(ll.clip_fd, F_GETFD);
  if (flags < 0 || fcntl(ll.clip_fd, F_SETFD, flags & ~FD_CLOEXEC) != 0) {
    return;
  }
  char buf[64];
  snprintf(buf, sizeof(buf), "%d:%s", ll.clip_fd, ll.clip_tool);
  os_setenv(CLIP_ENV, buf, 1);
}

/// In the editor process: takes the helper socket passed by the UI process, if any.
static bool take_clipboard_helper(void)
{
  const char *v = os_getenv_noalloc(CLIP_ENV);
  if (v == NULL) {
    return false;
  }
  char *val = xstrdup(v);
  os_unsetenv(CLIP_ENV);  // not for the editor's own children
  bool ok = false;
  char *colon = strchr(val, ':');
  if (colon != NULL) {
    *colon = NUL;
    char *end;
    long fd = strtol(val, &end, 10);
    static const char *const tools[] = { "wl-clipboard", "xclip", "xsel" };
    const char *tool = NULL;
    for (size_t i = 0; i < ARRAY_SIZE(tools); i++) {
      if (strcmp(colon + 1, tools[i]) == 0) {
        tool = tools[i];
      }
    }
    struct stat st;
    // Only an inherited socket: not some other file that happens to have that number.
    if (*end == NUL && end != val && fd > 2 && fd < INT_MAX && tool != NULL
        && fstat((int)fd, &st) == 0 && S_ISSOCK(st.st_mode)
        && fcntl((int)fd, F_SETFD, FD_CLOEXEC) == 0) {
      ll.clip_fd = (int)fd;
      ll.clip_tool = tool;
      ok = true;
    }
  }
  xfree(val);
  return ok;
}
#endif

#ifdef __linux__
# define GIT_WATCH_ENV "WGVIM_GIT_WATCH"

// The .git watch (|wgvim-sandbox-git|).
//
// The project is writable inside the sandbox, and so is its .git. Git runs commands named in
// .git/config (core.fsmonitor, core.pager, aliases, filters, ...) and the hooks, outside the
// sandbox and often without being asked to: a shell prompt that shows the branch runs git status.
// Landlock cannot make .git read-only inside a writable project, so instead a watcher process
// records those files at startup and, when wgvim exits, reports any that changed.
//
// The watcher is forked before the sandbox is applied, so it is outside every sandbox domain:
// sandboxed processes cannot ptrace it (Landlock), nor signal it (Landlock ABI 6), and on older
// kernels, where they could kill it, the process that started it says so at exit. It only reads
// files (never following symlinks) and writes its report to stderr; it runs nothing.

# define GIT_MAX_TEXT (256 * 1024)   // config files kept for the report
# define GIT_MAX_HASH (16u << 20)    // bytes hashed per file

static pid_t git_watch_pid = 0;  // the watcher, in the process that started it
static int git_watch_fd = -1;    // its socket: EOF tells it that wgvim exits
static char *git_watch_root = NULL;  // the project it watches (also for :checkhealth)
static int git_watch_nfiles = -1;    // files it recorded

static void git_add(GitSnap *s, const char *path, bool keep_text)
{
  struct stat st;
  if (s->n >= GIT_MAX_FILES || lstat(path, &st) != 0) {
    return;
  }
  for (int i = 0; i < s->n; i++) {
    if (strcmp(s->f[i].path, path) == 0) {
      return;
    }
  }
  context_sha256_T ctx;
  sha256_start(&ctx);
  uint32_t mode = (uint32_t)st.st_mode;
  sha256_update(&ctx, (uint8_t *)&mode, sizeof(mode));
  char *text = NULL;
  if (S_ISLNK(st.st_mode)) {
    char t[4096];
    ssize_t n = readlink(path, t, sizeof(t));
    sha256_update(&ctx, (uint8_t *)t, n > 0 ? (size_t)n : 0);
  } else if (S_ISREG(st.st_mode)) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd >= 0) {
      size_t total = 0;
      size_t cap = keep_text ? GIT_MAX_TEXT : 0;
      text = keep_text ? xmalloc(cap + 1) : NULL;
      uint8_t buf[8192];
      ssize_t n;
      while (total < GIT_MAX_HASH && (n = read(fd, buf, sizeof(buf))) > 0) {
        sha256_update(&ctx, buf, (size_t)n);
        if (text != NULL && total < cap) {
          size_t k = MIN((size_t)n, cap - total);
          memcpy(text + total, buf, k);
        }
        total += (size_t)n;
      }
      close(fd);
      if (text != NULL) {
        text[MIN(total, cap)] = NUL;
      }
    }
  }
  GitFile *f = &s->f[s->n++];
  sha256_finish(&ctx, f->digest);
  f->path = xstrdup(path);
  f->text = text;
}

/// Adds the entries of directory `dir` (and of its subdirectories, one level: husky keeps its
/// hook runner in one).
static void git_add_dir(GitSnap *s, const char *dir, int depth)
{
  DIR *d = opendir(dir);
  struct dirent *e;
  while (d != NULL && (e = readdir(d)) != NULL) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
      continue;
    }
    char *p = join_path(dir, e->d_name);
    struct stat st;
    git_add(s, p, false);
    if (depth == 0 && lstat(p, &st) == 0 && S_ISDIR(st.st_mode)) {
      git_add_dir(s, p, 1);
    }
    xfree(p);
  }
  if (d != NULL) {
    closedir(d);
  }
}

/// Calls `fn` for each value of `key` (lowercase) in sections named `section` (lowercase, or a
/// prefix ending in '*') of git config text. Enough of git's syntax for hooksPath and includes.
static void git_config_values(const char *text, const char *section, const char *key,
                              void (*fn)(const char *value, void *data), void *data)
{
  char sec[64] = "";
  const char *p = text;
  while (p != NULL && *p != NUL) {
    const char *eol = strchr(p, '\n');
    size_t len = eol ? (size_t)(eol - p) : strlen(p);
    char line[1024];
    len = MIN(len, sizeof(line) - 1);
    memcpy(line, p, len);
    line[len] = NUL;
    p = eol ? eol + 1 : NULL;
    char *l = skipwhite(line);
    if (*l == '[') {
      // "[core]", "[includeIf \"gitdir:...\"]": the name up to a space, '.' or ']'
      size_t k = 0;
      for (l++; *l != NUL && *l != ']' && *l != ' ' && *l != '\t' && *l != '.'
           && k < sizeof(sec) - 1; l++) {
        sec[k++] = (char)TOLOWER_ASC(*l);
      }
      sec[k] = NUL;
      continue;
    }
    size_t slen = strlen(section);
    bool match = section[slen - 1] == '*' ? strncmp(sec, section, slen - 1) == 0
                                           : strcmp(sec, section) == 0;
    if (!match) {
      continue;
    }
    char *eq = strchr(l, '=');
    if (eq == NULL) {
      continue;
    }
    char *kend = eq;
    while (kend > l && (kend[-1] == ' ' || kend[-1] == '\t')) {
      kend--;
    }
    if ((size_t)(kend - l) != strlen(key) || strncasecmp(l, key, strlen(key)) != 0) {
      continue;
    }
    char *v = skipwhite(eq + 1);
    char *end;
    if (*v == '"') {
      v++;
      end = strchr(v, '"');
    } else {
      end = v + strcspn(v, "#;");
    }
    if (end == NULL) {
      end = v + strlen(v);
    }
    while (end > v && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r')) {
      end--;
    }
    *end = NUL;
    if (*v != NUL) {
      fn(v, data);
    }
  }
}

typedef struct {
  GitSnap *s;
  const char *base;  // relative paths are relative to this
  bool dir;          // add a directory's entries (hooksPath), or one file (include.path)
} GitValueCtx;

static void git_value_path(const char *value, void *data)
{
  GitValueCtx *c = data;
  char *p;
  if (value[0] == '~' && value[1] == '/') {
    const char *home = os_getenv_noalloc("HOME");
    p = join_path(home ? home : "/", value + 2);
  } else {
    p = value[0] == '/' ? xstrdup(value) : join_path(c->base, value);
  }
  if (c->dir) {
    git_add_dir(c->s, p, 0);
  } else {
    git_add(c->s, p, true);
  }
  xfree(p);
}

/// Adds what git takes commands from in git directory `gitdir` (of the worktree `worktree`).
static void git_collect(GitSnap *s, const char *gitdir, const char *worktree, int depth)
{
  int first = s->n;
  static const char *const configs[] = { "config", "config.worktree" };
  for (size_t i = 0; i < ARRAY_SIZE(configs); i++) {
    char *p = join_path(gitdir, configs[i]);
    git_add(s, p, true);
    xfree(p);
  }
  char *hooks = join_path(gitdir, "hooks");
  git_add_dir(s, hooks, 0);
  xfree(hooks);
  // core.hooksPath (often a directory in the project: .husky, .githooks) and included files.
  for (int i = first; i < s->n && i < first + 2; i++) {
    if (s->f[i].text != NULL) {
      GitValueCtx hc = { s, worktree, true };
      git_config_values(s->f[i].text, "core", "hookspath", git_value_path, &hc);
      GitValueCtx ic = { s, gitdir, false };
      git_config_values(s->f[i].text, "include", "path", git_value_path, &ic);
      git_config_values(s->f[i].text, "includeif*", "path", git_value_path, &ic);
    }
  }
  if (depth < 4) {
    // Submodules (and theirs), and the per-worktree config of linked worktrees.
    static const char *const subs[] = { "modules", "worktrees" };
    for (size_t i = 0; i < ARRAY_SIZE(subs); i++) {
      char *dir = join_path(gitdir, subs[i]);
      DIR *d = opendir(dir);
      struct dirent *e;
      while (d != NULL && (e = readdir(d)) != NULL) {
        if (e->d_name[0] != '.') {
          char *g = join_path(dir, e->d_name);
          git_collect(s, g, worktree, depth + 1);
          xfree(g);
        }
      }
      if (d != NULL) {
        closedir(d);
      }
      xfree(dir);
    }
  }
}

static GitSnap *git_snapshot(const char *root)
{
  GitSnap *s = xcalloc(1, sizeof(GitSnap));
  char *gitdir = join_path(root, ".git");
  git_collect(s, gitdir, root, 0);
  xfree(gitdir);
  return s;
}

static const GitFile *git_find(const GitSnap *s, const char *path)
{
  for (int i = 0; i < s->n; i++) {
    if (strcmp(s->f[i].path, path) == 0) {
      return &s->f[i];
    }
  }
  return NULL;
}

/// Writes `str` to stderr with anything but printable ASCII and tabs replaced by '?': names and
/// lines from the project must not carry escape sequences to the terminal.
static void git_put(const char *str, size_t max)
{
  char buf[256];
  size_t k = 0;
  for (; *str != NUL && k < max && k < sizeof(buf) - 1; str++) {
    unsigned char c = (unsigned char)(*str);
    buf[k++] = (c == '\t' || (c >= 0x20 && c < 0x7f)) ? (char)c : '?';
  }
  buf[k] = NUL;
  fputs(buf, stderr);
}

/// Prints the lines of `now` that are not in `before` (at most 10).
static void git_put_added_lines(const char *before, const char *now)
{
  int shown = 0;
  const char *p = now;
  while (p != NULL && *p != NUL && shown < 10) {
    const char *eol = strchr(p, '\n');
    size_t len = eol ? (size_t)(eol - p) : strlen(p);
    char line[512];
    size_t k = MIN(len, sizeof(line) - 1);
    memcpy(line, p, k);
    line[k] = NUL;
    p = eol ? eol + 1 : NULL;
    bool old = false;
    for (const char *q = before ? before : ""; *q != NUL && !old;) {
      const char *qe = strchr(q, '\n');
      size_t ql = qe ? (size_t)(qe - q) : strlen(q);
      old = ql == len && strncmp(q, line, len) == 0;
      q = qe ? qe + 1 : q + ql;
    }
    if (!old && *skipwhite(line) != NUL) {
      fputs("             + ", stderr);
      git_put(line, 120);
      fputs("\n", stderr);
      shown++;
    }
  }
}

static void git_report(const GitSnap *before, const GitSnap *now, const char *root)
{
  bool header = false;
  for (int pass = 0; pass < 2; pass++) {
    const GitSnap *a = pass == 0 ? now : before;
    const GitSnap *b = pass == 0 ? before : now;
    for (int i = 0; i < a->n; i++) {
      const GitFile *f = &a->f[i];
      const GitFile *other = git_find(b, f->path);
      const char *what = other == NULL ? (pass == 0 ? "added" : "removed")
                         : (pass == 0 && memcmp(other->digest, f->digest, SHA256_SUM_SIZE) != 0)
                         ? "changed" : NULL;
      if (what == NULL) {
        continue;
      }
      if (!header) {
        fputs("\nwgvim: while wgvim ran, these files changed that git takes commands from, and "
              "runs outside the sandbox (in ", stderr);
        git_put(root, 200);
        fputs("):\n", stderr);
        header = true;
      }
      const char *rel = f->path;
      if (path_within(f->path, root) && f->path[strlen(root)] == '/') {
        rel = f->path + strlen(root) + 1;
      }
      fprintf(stderr, "  %-9s  ", what);
      git_put(rel, 200);
      fputs("\n", stderr);
      if (pass == 0 && f->text != NULL) {
        git_put_added_lines(other != NULL ? other->text : NULL, f->text);
      }
    }
  }
  if (header) {
    fputs("If you made these changes yourself (git remote add, git branch -u, installing hooks), "
          "there is nothing to do. Otherwise check them before you run git there again "
          "(:help wgvim-sandbox-git).\n", stderr);
  }
}

/// The watcher: records, waits for wgvim to exit (EOF on `fd`), compares, reports.
static void git_watch_main(int fd, const char *root)
  FUNC_ATTR_NORETURN
{
  GitSnap *before = git_snapshot(root);
  int32_t n = before->n;
  if (write(fd, &n, sizeof(n)) != (ssize_t)sizeof(n)) {
    _exit(1);
  }
  char c;
  ssize_t r;
  while ((r = read(fd, &c, 1)) != 0) {
    if (r < 0 && errno != EINTR) {
      break;
    }
  }
  GitSnap *now = git_snapshot(root);
  git_report(before, now, root);
  fflush(stderr);
  _exit(0);
}

/// Starts the watcher for the working directory's repository, if it has one that the sandbox can
/// write to. Call before the restrictions, in the outermost wgvim process.
static void git_watch_start(void)
{
  char *root = real_path(".");
  if (root == NULL) {
    return;
  }
  char *dotgit = join_path(root, ".git");
  struct stat st;
  bool ok = lstat(dotgit, &st) == 0 && S_ISDIR(st.st_mode) && writable_rule(root) != NULL;
  xfree(dotgit);
  int sv[2];
  if (!ok || socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0) {
    xfree(root);
    return;
  }
  pid_t pid = fork();
  if (pid < 0) {
    close(sv[0]);
    close(sv[1]);
    xfree(root);
    return;
  }
  if (pid == 0) {
    for (int sig = 1; sig < NSIG; sig++) {
      signal(sig, SIG_DFL);
    }
    // Survive a stray Ctrl-C, and still write the report after wgvim exits, when the shell
    // has taken the terminal back (with "stty tostop", SIGTTOU would stop it).
    signal(SIGINT, SIG_IGN);
    signal(SIGQUIT, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTTOU, SIG_IGN);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    int null = open("/dev/null", O_RDWR);
    dup2(null, 0);
    dup2(null, 1);  // stderr (2) stays: the report goes there
    dup2(sv[1], 3);
    for (int i = 4; i < 1024; i++) {
      close(i);
    }
    if (chdir("/") != 0) {
      _exit(1);
    }
    git_watch_main(3, root);
  }
  close(sv[1]);
  // The record must exist before anything in the project can run.
  struct pollfd pfd = { .fd = sv[0], .events = POLLIN };
  int32_t n = -1;
  if (poll(&pfd, 1, 5000) != 1 || read(sv[0], &n, sizeof(n)) != (ssize_t)sizeof(n)) {
    WLOG("sandbox: the .git watch did not start");
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    close(sv[0]);
    xfree(root);
    return;
  }
  git_watch_pid = pid;
  git_watch_fd = sv[0];
  git_watch_root = root;
  git_watch_nfiles = n;
  ILOG("sandbox: watching %d git files in %s", n, root);
  // For :checkhealth in the editor process the TUI starts (it does not watch itself).
  char buf[MAXPATHL + 32];
  snprintf(buf, sizeof(buf), "%d:%s", n, root);
  os_setenv(GIT_WATCH_ENV, buf, 1);
}

/// In the editor process started by the TUI: what the TUI's watcher watches, for :checkhealth.
static void take_git_watch_info(void)
{
  const char *v = os_getenv_noalloc(GIT_WATCH_ENV);
  if (v == NULL) {
    return;
  }
  char *end;
  long n = strtol(v, &end, 10);
  if (*end == ':' && end[1] == '/') {
    git_watch_nfiles = (int)n;
    git_watch_root = xstrdup(end + 1);
  }
  os_unsetenv(GIT_WATCH_ENV);
}
#endif

/// Copies `data` to (or, with `paste`, reads) register "+" or "*" through the clipboard helper.
///
/// @return the pasted text, or "" after a copy; sets `err` on failure.
String landlock_clipboard(bool paste, bool primary, String data, Arena *arena, Error *err)
{
#ifdef __linux__
  if (ll.clip_fd < 0) {
    api_set_error(err, kErrorTypeException, "no clipboard helper (see :help wgvim-sandbox)");
    return (String)STRING_INIT;
  }
  unsigned char hdr[6] = { paste ? 'p' : 'c', primary ? '*' : '+' };
  uint32_t len = paste ? 0 : (uint32_t)MIN(data.size, CLIP_MAX);
  memcpy(hdr + 2, &len, 4);
  uint32_t rlen = CLIP_FAIL;
  bool ok = full_io(ll.clip_fd, hdr, sizeof(hdr), false)
            && (len == 0 || full_io(ll.clip_fd, data.data, len, false))
            && full_io(ll.clip_fd, &rlen, 4, true);
  if (!ok || rlen == CLIP_FAIL || rlen > CLIP_MAX) {
    api_set_error(err, kErrorTypeException, "clipboard: %s failed", ll.clip_tool);
    return (String)STRING_INIT;
  }
  String out = { .data = arena_alloc(arena, rlen + 1, false), .size = rlen };
  if (rlen > 0 && !full_io(ll.clip_fd, out.data, rlen, true)) {
    api_set_error(err, kErrorTypeException, "clipboard: %s failed", ll.clip_tool);
    return (String)STRING_INIT;
  }
  out.data[rlen] = NUL;
  return out;
#else
  (void)paste; (void)primary; (void)data; (void)arena;
  api_set_error(err, kErrorTypeException, "no clipboard helper");
  return (String)STRING_INIT;
#endif
}

/// Whether the TUI may connect to `addr` (for :restart and :connect): only to wgvim's own
/// sockets, in the temp root, when the sandbox is active.
bool landlock_connect_ok(const char *addr)
{
  if (!landlock_active()) {
    return true;
  }
#ifdef __linux__
  char *real = real_path(addr);
  char *root = real_path(ll.temp_root);  // no trailing separator
  bool ok = real != NULL && root != NULL && path_within(real, root);
  xfree(real);
  xfree(root);
  return ok;
#else
  (void)addr;
  return true;
#endif
}

/// Applies the sandbox. Exits with an error if `mode` is "require" and it cannot be applied.
///
/// @param mode      "on", "off", "require", or NULL for $WGVIM_SANDBOX (default "on")
/// @param allow_rw  extra read-write paths (--sandbox-allow)
/// @param allow_ro  extra read-only paths (--sandbox-allow-ro)
/// @param tui       this process will be the TUI client, which connects to its server
void landlock_init(const char *mode, char **allow_rw, int n_rw, char **allow_ro, int n_ro,
                   bool tui)
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
    attr.scoped = LL_SCOPE_ABSTRACT_UNIX_SOCKET | LL_SCOPE_SIGNAL;
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

  // Landlock and seccomp apply to the calling thread (and what it starts later): there must
  // be no other thread yet.
  if (count_threads() != 1) {
    ll.status = kLandlockFailed;
    ll.reason = "other threads were already running";
    ll.network = ll.scoped = false;
    close(rfd);
    xfree(temp_root);
    goto done;
  }
  // The clipboard helper is forked before the restrictions: by the TUI process, which passes it
  // to the editor process it starts; or by the editor process when there is no TUI.
  if (tui) {
    start_clipboard_helper();
    pass_clipboard_helper();
  } else if (!take_clipboard_helper()) {
    start_clipboard_helper();
  }
  // The .git watch belongs to the outermost wgvim process: the TUI process, or the editor
  // process when no TUI started it. An editor started with --embed by another UI is skipped:
  // that UI would not show its report.
  if (tui || !embedded_mode) {
    git_watch_start();
  } else {
    take_git_watch_info();
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
  ll.connect = tui;
  ll.seccomp = install_seccomp(tui);
  if (!ll.seccomp) {
    WLOG("sandbox: the system call filter could not be installed: %s", strerror(errno));
  }
  if (temp_root != NULL) {
    os_setenv("TMPDIR", temp_root, 1);  // child programs: compilers, clangd preambles, ...
    ll.temp_root = temp_root;
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

/// At exit, in the process that started the .git watch: lets the watcher compare and report, and
/// waits briefly so that its report comes before the shell prompt. Call after the terminal is
/// restored.
void landlock_git_check(void)
{
#ifdef __linux__
  if (git_watch_pid <= 0) {
    return;
  }
  pid_t pid = git_watch_pid;
  git_watch_pid = 0;
  int st;
  if (waitpid(pid, &st, WNOHANG) == pid) {
    // Killed (on kernels without Landlock signal scoping, a sandboxed process could): nothing
    // was compared, so say so rather than stay silent.
    fprintf(stderr, "\nwgvim: the .git watch for %s stopped early, so changes to .git/config "
            "and the git hooks were not checked: check them before you run git there "
            "(:help wgvim-sandbox-git).\n", git_watch_root);
    return;
  }
  close(git_watch_fd);  // EOF: the watcher compares and reports
  git_watch_fd = -1;
  for (int i = 0; i < 150 && waitpid(pid, &st, WNOHANG) == 0; i++) {
    usleep(20000);
  }
#endif
}

/// Information for :checkhealth and tests (|nvim__sandbox_info()|).
Dict landlock_info(Arena *arena)
{
  static const char *const names[] = { "off", "active", "unavailable", "failed" };
  Dict rv = arena_dict(arena, 13);
  PUT_C(rv, "status", CSTR_AS_OBJ(names[ll.status]));
  PUT_C(rv, "abi", INTEGER_OBJ(ll.abi));
  PUT_C(rv, "reason", CSTR_AS_OBJ(ll.reason ? ll.reason : ""));
  PUT_C(rv, "network", BOOLEAN_OBJ(ll.network));
  PUT_C(rv, "scoped", BOOLEAN_OBJ(ll.scoped));
  PUT_C(rv, "seccomp", BOOLEAN_OBJ(ll.seccomp));
  PUT_C(rv, "connect", BOOLEAN_OBJ(ll.connect));
  PUT_C(rv, "clipboard", CSTR_AS_OBJ(ll.clip_tool ? ll.clip_tool : ""));
#ifdef __linux__
  PUT_C(rv, "git_watch", CSTR_AS_OBJ(git_watch_root ? git_watch_root : ""));
  PUT_C(rv, "git_watch_files", INTEGER_OBJ(git_watch_nfiles));
#endif
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
