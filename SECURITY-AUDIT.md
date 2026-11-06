# wgvim network and security audit

Policy (set by the wgvim maintainers): the editor needs no network access.
Network functionality that is near-identical to what **Vim 8.2** already had may
stay after review; anything newer than Vim 8.2 is audited or removed.

Scope: code reachable from the editor itself. Out of scope, and impossible to
enforce from inside the editor: any program the editor can start (`:!curl`,
`jobstart()`, `vim.system()`, `:terminal`, LSP servers, remote-plugin hosts). For a
hard guarantee, run wgvim in a network-isolated container or network namespace.

Status: rows marked **DONE** are implemented on branch `wgvim-hardening` (commit shown);
the others are open decisions. Evidence is from reading this tree at the commit named
in `NOTICE`. How each DONE row was tested is in the commit message.

## Findings

| # | Surface | Where | In Vim 8.2? | Proposed |
|---|---------|-------|-------------|----------|
| 1 | `vim.net.request()` (runs `curl`) and the `http(s)://` buffer reader | `runtime/lua/vim/net*`, `runtime/plugin/net.lua` | No | **DONE** `1197d43`: `vim.net` is a stub that errors; `plugin/net.lua` deleted |
| 2 | `vim.pack` (runs `git clone`/`fetch` for plugins) | `runtime/lua/vim/pack*`, `ftplugin/nvim-pack.lua` | No | **DONE** `1197d43`: `vim.pack` is a stub that errors (`:packupdate`/`:packdel` are in the C command table); modules and ftplugin deleted. Plugins go in `pack/*/start` and load with `:packadd` |
| 3 | RPC server on TCP (`--listen host:port`, `serverstart()`, `v:servername`) | `src/nvim/event/socket.c`, `msgpack_rpc/server.c` | No (Vim 8.2 `+clientserver` is X11-only) | **DONE** `abc452f`: `host:port` is refused; Unix-domain sockets and pipes only |
| 4 | `--remote-ui` / `--server host:port` TCP client for the TUI | `src/nvim/ui_client.c` | No | **DONE** `abc452f`: TCP refused |
| 5 | LSP client connecting to a server over TCP (`vim.lsp.rpc.connect`) | `runtime/lua/vim/lsp/rpc.lua` | No LSP at all | **DONE** `1197d43`: TCP refused; stdio spawn (clangd) and pipe/Unix-socket connect still work |
| 6 | Lua access to sockets through luv: `tcp_*`, `udp_*`, `getaddrinfo`, `getnameinfo` (33 functions) | vendored luv | No | **DONE** `PatchLuv.cmake`: removes the 33 registrations at build time and fails if the source changes. The C code stays compiled but is unreachable from Lua |
| 7 | Spell-file auto-download (uses #1; default host `ftp.nluug.nl`) | `runtime/lua/nvim/spellfile.lua` | Yes (`spellfile.vim`, over netrw) | **DONE** `1197d43`: downloader removed; a missing spell file only warns |
| 8 | `sockconnect()` / `channel_connect()` TCP client | `src/nvim/channel.c`, `socket.c` | Yes (`ch_open("host:port")`) | **DONE** `abc452f`: TCP removed, local sockets stay |
| 9 | netrw remote protocols (ftp, scp, sftp, rcp, rsync, dav, http via curl/wget) | `runtime/pack/dist/opt/netrw` | Yes | **DONE** `1197d43`: every remote entry point refuses and the URL handlers are removed; local browsing and `file://` unchanged |
| 10 | `vim.ui.open()` / `gx` (starts the system URL opener) | `runtime/lua/vim/ui.lua` | Yes (netrw `gx`) | Keep; it only starts a local program |
| 11 | `:checkhealth` runs `curl --version` | `runtime/lua/vim/health/health.lua` | No | **DONE** `1197d43`: probes removed |
| 12 | OSC 52 clipboard (writes an escape sequence to the terminal) | `runtime/plugin/osc52.lua` | No | Keep; local terminal output only |
| 13 | Telemetry / update checks / phone-home | whole tree | n/a | **None found** in the editor. (LSP protocol constants mention `telemetry/event`; that is for servers, which are out of scope.) |
| 14 | LuaJIT `ffi`: Lua can call libc directly, including `socket()`/`connect()` | built into LuaJIT; nothing in `runtime/` or `src/` uses it | No | **DONE** (`nlua_disable_ffi` in `src/nvim/lua/executor.c`): removed from the main state and from worker-thread states; `require('ffi')` raises "wgvim: the LuaJIT 'ffi' library is disabled …" every time and the attempt is written to the log (WRN). Third-party plugins that use `ffi` will fail with that message |
| 15 | `'exrc'`: runs `.nvim.lua` / `.nvimrc` / `.exrc` from the current and parent directories (gated by the `:trust` prompt, but a trusted file can add the project to `runtimepath` and load further unchecked code) | `src/nvim/main.c`, `runtime/lua/vim/_core/exrc.lua` | Yes (`'exrc'`, without trust) | **DONE**: `'exrc'` is `immutable` (setting it gives E519), the startup code that sourced the files is removed, and `vim/_core/exrc.lua` is deleted. `:trust` / `vim.secure` remain for plugins that use them |
| 16 | Tree-sitter parsers: any `parser/<lang>.so` on `runtimepath`, or any path passed to `vim.treesitter.language.add()`, was `dlopen()`ed (native code runs immediately, bypassing rows 6 and 14) | `runtime/lua/vim/treesitter/language.lua`, `src/nvim/lua/treesitter.c` | No | **DONE**: only `<libdir>/parser/*.so` is searched; the C loader resolves symlinks, refuses anything outside that directory, refuses names not bundled at build time, and checks the SHA256 against hashes compiled into the binary (`cmake/GenerateParserHashes.cmake`). Residual: the file is hashed, then opened by path, so the install directory must be writable only by root. WASM parsers are not compiled in (`ENABLE_WASMTIME=OFF`) |
| 17 | Native Lua modules: `package.loadlib()`, `package.cpath`, and `require` of `lua/*.so` from `runtimepath` | LuaJIT, `runtime/lua/vim/_init_packages.lua`, `vim/loader.lua` | No | **DONE** (`nlua_disable_native_modules` in `executor.c`, main and thread states): `package.loadlib` raises an error and logs WRN, `package.cpath` is empty, the C searchers are removed. Built-in modules (luv, lpeg, mpack, …) are linked in and unaffected; plugins that ship compiled `.so` helpers will not load |
| 18 | RPC server started automatically at `$XDG_RUNTIME_DIR/wgvim.<pid>.0`; any process of the same user could connect and run Lua (`nvim_exec_lua`) | `src/nvim/msgpack_rpc/server.c` | No (Vim 8.2 `+clientserver` is X11 and off in your build) | **DONE**: no server unless `--listen` or `serverstart()`; `v:servername` is empty by default. `--remote-ui`, `serverlist({peer=true})` and nested-editor features need an explicit `--listen` |
| 19 | Language providers (Python 3, Ruby, Node.js, Perl) and remote plugins: start external interpreters that load code from outside the editor; the provider health check could also fetch `https://pypi.org` with `curl`/`python` | `runtime/autoload/provider/*`, `runtime/autoload/remote/*`, `runtime/plugin/rplugin.vim`, `runtime/lua/vim/provider*` | Partly (Vim has built-in `+python3` etc.; off in your build) | **DONE**: removed; `has('python3')` etc. are 0, `:python3`/`:ruby`/`:perl` report a missing provider (C side accepts only the clipboard provider), `:checkhealth` checks only the clipboard. The clipboard provider (`xclip`, `wl-copy`, …) stays |
| 20 | LSP server configs: any `lsp/<name>.lua` on `runtimepath` could define the command `vim.lsp.enable()` runs | `runtime/lua/vim/lsp.lua` | No | **DONE**: `lsp/*.lua` is read only from `stdpath('config')` (incl. `after/`) and `$VIMRUNTIME`. Configs set with `vim.lsp.config()` in Lua (your clangd setup) are unaffected |
| 21 | Compiler/linker hardening came from the build host's compiler defaults (e.g. Ubuntu), not from the build system; a plain RHEL 9 `gcc` build would lack most of it | `src/nvim/CMakeLists.txt`, `cmake.deps/CMakeLists.txt` | n/a | **DONE** (option `WGVIM_HARDENING`, default ON; each flag only if supported): editor gets PIE, `_FORTIFY_SOURCE=3` (2 on GCC < 12), `-fstack-protector-strong`, `-fstack-clash-protection`, `-fcf-protection=full`, `-ftrivial-auto-var-init=zero`, `-fno-strict-overflow`, `-z relro -z now -z noexecstack -z separate-code`. Dependencies and parsers get stack protector, stack-clash, CET, `_FORTIFY_SOURCE=2`, full RELRO. Verified with `readelf`: PIE, BIND_NOW, RELRO, non-executable stack, x86 SHSTK. IBT is not marked on the final binary because LuaJIT's hand-written assembly VM (`lj_vm.o`) has no IBT markers; parsers have both IBT and SHSTK. Side effect: `-z now` exposed a latent bug in the cpp parser build (C99 made `static_assert` an undefined function call); parsers are now built as C11 |
| 22 | Unit-test code compiled into the shipped binary (`UNIT_TESTING`: writable global `malloc`/`free` function pointers in `memory.c`, plus test fixtures) | `src/nvim/CMakeLists.txt` | n/a | **DONE**: unit tests removed (they required ffi inside the editor, row 14); the fixtures and `UNIT_TESTING` are no longer built into `wgvim`. Coverage now comes from the functional tests (`-D ENABLE_GCOV=ON`) |
| 23 | Bugs found by fuzzing (`test/fuzz/`, libFuzzer + ASan/UBSan) in the parsers of terminal output (`vterm`) and terminal input (`termkey`) | `src/nvim/vterm/{state,parser}.c`, `src/nvim/tui/termkey/{termkey,driver-csi}.c` | n/a | **DONE**: (a) `ESC [ b` (REP) with no preceding character looped forever and froze the editor — 3 bytes printed in `:terminal` were enough, and the frozen editor ignored SIGTERM; (b) `termkey` read `c0[-1]` out of bounds for a CSI-u key with a missing/negative code (from the outer terminal); (c) a non-digit CSI parameter byte tripped an `assert` (abort in debug builds); (d) signed-integer overflows on huge CSI/OSC numbers (UB); (e) left shift of a negative value in DECRQSS handling (UB). Second round (crash-tolerant runs, ~40 min each), memory-safety bugs: (f) **heap buffer overflow**: a CSI sequence with more than 32 parameters (`ESC [` + many `1;`) wrote attacker-chosen numbers past the parser's `args[]` into the VTerm heap object — confirmed to crash the release editor (SIGSEGV) from `:terminal` output; (g) heap overflow writing one codepoint past `tmpbuffer` in the UTF-8 decoder; (h) heap overflow from restoring a saved cursor (`ESC 7` … `ESC 8`) after the terminal shrank; (i) negative-size `memmove` from a scroll region left inverted by a resize; (j) column −1 accesses from a double-width line on a 1-column terminal; (k) cursor/count `int` overflows, fixed by clamping CSI numbers to 65535; (l) `termkey`: **stack buffer overflow** writing past the subparameter array (`ESC [ 1 ; 2 : 3 : 4 ~`), and a read through an **uninitialized pointer** for `ESC [ u` (seen as use-after-free/SEGV) — both reachable from bytes the outer terminal delivers. Found later by the CI fuzz job: (m) in libvterm's OSC 52 base64 decoder the partial value was not reset at `=` padding, so its high bits later came back as a bogus sextet count (a shift overflow, UB). wgvim does not register the OSC 52 callbacks (row 24), so this is reachable only in the fuzz harness here, but upstream Neovim decodes OSC 52 from `:terminal` programs. All fixed; crash inputs are in `test/fuzz/corpus/`; (a), (f), (h), (i) have functional regression tests. (f) and the other vterm bugs are present in upstream Neovim at the snapshot commit, so they should be reported to the Neovim project privately (GitHub security advisory) |
| 24 | OSC 52 from programs in `:terminal`: could set the system clipboard (`"+` / `"*`) | `src/nvim/terminal.c` | No (Vim's `:terminal` has no OSC 52) | **DONE**: the selection callbacks are no longer registered, so libvterm does not decode OSC 52; the sequence only reaches Lua as a `TermRequest` event (no default handler acts on it). Test: `terminal/clipboard_spec.lua` checks the clipboard provider is never called |
| 25 | `'modelineexpr'`: when on, a file's modeline may set options that are evaluated as expressions (`'foldexpr'`, `'indentexpr'`, `'complete'` F{func}, …) | `src/nvim/options.lua` | Yes | **DONE**: `immutable` (always off, E519), so neither a file nor a plugin can enable it. Old tests that turned it on are skipped |
| 26 | Not a security issue; found by the RHEL 9 CI job. `:syntax iskeyword` added to the previous value instead of replacing it, so on systems where `/bin/sh` is bash (RHEL, Fedora) the `:` that `syntax/sh.vim` adds stayed in effect for `syntax/tutor.vim`, and keywords such as `NOTE` were no longer highlighted | `src/nvim/syntax.c` (`syn_cmd_iskeyword`) | No (Vim rebuilds the table) | **DONE**: the table is cleared before it is parsed, as `buf_init_isk_chartab()` does. Test: `ex_cmds/syntax_iskeyword_spec.lua`. Present in upstream Neovim at the snapshot commit (an ordinary bug, fine to report publicly) |
| 27 | Defence in depth: nothing limited what a compromised editor (an exploited parser bug, a malicious plugin) or the programs it starts could read or write — `~/.ssh`, other projects, shell startup files — or connect to | `src/nvim/os/landlock.c`, `src/nvim/main.c` | No | **DONE**: a Landlock sandbox applied in `main()` before any config or plugin runs, inherited by `:!`, `:terminal`, jobs and LSP servers, and impossible to lift. Read-write: the current directory tree, files and directories named on the command line, state/cache/temp dirs; read-only: system paths, config, plugins, `$VIMRUNTIME`; `$HOME` as the current directory gives only its non-hidden entries; TCP blocked (ABI 4+), abstract Unix sockets outside the sandbox blocked (ABI 6+); `no_new_privs` (setuid programs cannot elevate). Probed at runtime; without Landlock (RHEL 9 before 9.6) wgvim runs unconfined unless `--sandbox require`. `--sandbox off`, `--sandbox-allow[-ro]`; `:checkhealth wgvim` lists the rules; refused opens say so in E212/E482/`[Permission Denied]`. Residual: other `/dev/pts` terminals of the same user are writable; UDP, signals and SysV IPC are not covered. Tests: `core/sandbox_spec.lua` (incl. clangd in CI) |
| 28 | Gaps left by Landlock alone: UDP and other protocols, System V IPC, signals to the user's other processes, and above all **connecting to existing Unix sockets** — the user D-Bus bus (`/run/user/<uid>/bus`, through which `systemd --user` runs a command outside the sandbox: a full escape), ssh-agent, gpg-agent, a podman/docker socket. Landlock controls pathname-socket `connect()` only from ABI 9 (`LANDLOCK_ACCESS_FS_RESOLVE_UNIX`, not in released kernels as of this audit) | `src/nvim/os/landlock.c`, `src/nvim/main.c`, `src/nvim/eval/funcs.c`, `src/nvim/ui_client.c`, `runtime/lua/vim/_core/server.lua` | n/a | **DONE**: a seccomp filter installed with the Landlock rules and inherited the same way: `socket()` only `AF_UNIX`; `connect()` refused (`EACCES`) except in the TUI process, whose `:restart`/`:connect` targets are checked against wgvim's temp root; `sendto()` with an address refused; System V IPC and io_uring refused (io_uring could open sockets past the filter, so it is refused from the first line of `main()` and libuv uses epoll); foreign ABIs (x32) refused. Landlock signal scope (ABI 6+). `sockconnect()` (E5435), `--remote*` and `--server` are disabled outright; `serverlist({peer})` lists own servers only. A check refuses to apply the sandbox if other threads already exist (both apply per thread). Residual: SSSD cache misses and syslog fail in child programs; filter is x86-64/AArch64 only. Tests: `core/sandbox_spec.lua`; upstream tests that needed `sockconnect()`, `--remote`, `--remote-ui` or `--server` are skipped (about 54 tests, including all of `core/remote_spec.lua`) |
| 29 | The sandbox is applied by wgvim's own code, so a compromise before it is applied (or a bug in it) is not covered; residual gaps (other `/dev/pts` terminals, signals on kernels before 6.12) | `contrib/selinux/`, `scripts/wgvim-selinux.sh` | n/a | **DONE (needs field testing)**: an SELinux module: domain `wgvim_t` for the installed binaries, inherited by everything wgvim starts; user home/tmp content read-write, system files read-only, no network, `connectto` only to itself, no `ssh_home_t`/`gpg_secret_t`, no capabilities, signals only to itself; own pty type for `:terminal`; `execmem` for LuaJIT. Installed in permissive mode by `scripts/wgvim-selinux.sh install`; `denials` (ausearch + audit2allow) before `enforce`. Compiled against the RHEL 9 policy in CI (AlmaLinux 9); not yet loaded on a real host |
| 30 | The sandbox's connect() block broke the clipboard tools (wl-copy, xclip, xsel cannot reach the display server) | `src/nvim/os/landlock.c`, `runtime/autoload/provider/clipboard.vim`, `runtime/lua/wgvim/clipboard.lua` | n/a | **DONE**: on a local desktop, a clipboard helper is forked just before the Landlock restriction, so it is not file-confined and may connect; it keeps the rest of the seccomp filter (Unix sockets only, no System V IPC or io_uring), drops the editor's signal handlers and fds, and dies with the editor. With the terminal UI, the TUI process forks the helper (the editor process it starts is already confined, and so would be a helper forked there; found in use: copying failed with "wl-clipboard failed") and passes the socket to the editor process as an inherited descriptor named in `$WGVIM_CLIPBOARD_FD`, which the editor checks is a socket, marks close-on-exec and removes from its environment, so its own children get neither. The clipboard programs are resolved to absolute paths once, before the sandbox is applied, and refused if they are inside any directory the sandbox can write to (a project directory in `$PATH`, say): the helper runs them unconfined, so a program planted there by a sandboxed process would otherwise escape it. The helper also runs them from `/`, not the project. Its protocol is fixed: copy or paste register `+`/`*`, with up to 64 MiB of text, running only the tool chosen at startup with fixed arguments (via `posix_spawn`, so the editor's fork handlers do not run). A compromised editor can therefore set or read the clipboard, nothing else through it. Over SSH, OSC 52 copy and paste of the last copy (no stalled OSC 52 reads). Tests: `core/sandbox_spec.lua` (round trip through stand-in tools whose store is outside the sandbox; SSH mode) |
| 31 | `.git` stays writable inside the sandbox (Landlock cannot carve a read-only subtree out of a writable one), so a compromised editor or a `:!`/`:terminal`/LSP program could write `.git/config` (core.fsmonitor, core.pager, aliases, filters) or a hook, which the user's **unsandboxed** git then runs later: a plain `git status`, as shell prompts run on their own, is enough. A delayed escape from the sandbox | `src/nvim/os/landlock.c`, `src/nvim/main.c`, `runtime/lua/wgvim/health.lua` | No | **DONE (detect, not prevent)**: in the outermost wgvim process (the TUI, or the editor when not `--embed`), a watcher is forked before the sandbox is applied, so it is outside every Landlock domain: sandboxed processes cannot ptrace it, nor (ABI 6) signal it; if it was killed anyway (older kernels), the parent says at exit that the check did not run. It records `.git/config`, `config.worktree`, every hook (one subdirectory level, for husky), a `core.hooksPath` directory, `include.path`/`includeIf` files, and the same for `.git/modules` and `.git/worktrees`: type, mode and SHA-256 of contents or symlink target, never following symlinks; it runs nothing. The editor waits for the record before reading the config. At exit, after the terminal is restored, it prints the added, removed and changed files and the lines added to config files, with anything but printable ASCII replaced (names and lines are attacker-controlled). Residual: a warning only, and only at exit (git run in another terminal meanwhile is not covered); only the working directory's repository; project scripts that hooks run (husky, pre-commit) are ordinary project files. The user chose warn + document over a read-only `.git` that would forbid creating top-level files. Tests: `core/sandbox_spec.lua` (changed/added/removed and added lines; silence when unchanged and `:checkhealth` info; `core.hooksPath`; escape sequences in names; once with the TUI); refused kill/ptrace from inside, and the early-stop message, checked by hand |
| 32 | The TUI process is the more privileged wgvim process: it may `connect()` (for `:restart`/`:connect`; the filter cannot check addresses, wgvim's code allows only its own sockets) and it decodes the editor's UI stream. A compromised editor plus a flaw in that decoding could take over the TUI and reach e.g. the D-Bus bus | `src/nvim/os/landlock.c`, `src/nvim/ui_client.c` | n/a | **ACCEPTED, documented** (`:help wgvim-sandbox-tui`): needs two flaws, the second in a small part of the code. Closing it means dropping `:connect` and reworking `:restart`. Without the TUI, no wgvim process may connect |

## Limits of what the editor can enforce

Removing the network API closes the *ordinary* routes, but Lua code running inside
the editor is still a programming environment. On the final build:

- `uv.new_tcp`, `uv.new_udp` and `uv.getaddrinfo` are gone, and LuaJIT's `ffi` is
  disabled (it could call `socket()` directly; that was demonstrated before it was removed).
  Tested: `require('ffi')` fails with a clear message in the main state and in threads.
- `io.popen`, `os.execute`, `:!`, `jobstart()` and `vim.system()` start other programs,
  which have their own network access.
- Native code from Lua: blocked (rows 16 and 17), but a program started with `:!` or
  `jobstart()` is native code too, so this does not change the sandbox conclusion below.

So these changes remove accidental and built-in network use; they are **not** a
sandbox. Treat plugins and any `init.lua` as trusted code, and enforce "no network"
at the OS level (network namespace, container without a network, or firewall rule).

## Related findings (not network)

- Dead `ZIG_BUILD` branches removed (2026-11-01). Docs for removed maintainer scripts
  (`MAINTAIN.md`, `runtime/doc/dev_vimpatch.txt`) are still upstream's.
- `:help` pages updated (2026-11-01) for the removed features: providers and remote plugins,
  `vim.pack`, `vim.net`, spell-file download, `'exrc'`, `'modelineexpr'`, automatic
  `v:servername`, `lsp/*.lua` lookup, TCP/UDP/DNS in `luvref`, `ffi`. `make lintdoc` passes.
- The per-user temp directory is now `wgvim.<user>`.
- Test coverage (see `COVERAGE.md`): functional tests cover 78.7% of lines; the parsers of
  untrusted input are among the least covered — `spellfile.c` 33% (spell files; Vim
  CVE-2026-45130 was here), `vterm/state.c` 59% (`:terminal` output), `tui/termkey` ~69%
  (terminal input). The old-style Vim tests raise the combined figure to 92.4%. These are the
  first candidates for more tests or fuzzing.
- Debug builds only: 22 functional tests that draw the tab line fail because the tab's window
  count is drawn as "A" instead of the digit. It happens with `WGVIM_HARDENING=OFF` too and
  not in Release builds. Narrowed down (2026-11-01): the digit is formatted correctly into the
  grid (`screenstring()` is right, and the formatted buffer is "4"), so the wrong character
  appears on the way to an attached UI. Not fixed; Release builds are unaffected.

## Reviewed, no change needed

- Temp files: the per-user temp directory is created 0700 and its owner and mode are
  checked before use (`vim_mktempdir()` in `src/nvim/fileio.c`).
- `:terminal` escape sequences: OSC 8 (hyperlinks), OSC 10/11 (colour queries, answered from
  'background') and OSC 133 (prompt marks) are handled. **Correction (2026-11-01):** OSC 52 *is*
  handled — a program running in `:terminal` can **set** the system clipboard
  (`term_selection_set()` in `terminal.c`); reading it was already disabled. Output of an
  untrusted program (e.g. `cat` of a downloaded file) could therefore replace what you paste
  next. **Removed** (row 24).
- `'modelineexpr'` is off by default and options that take expressions or function names
  (including `'complete'`) are marked as needing it; this covers Vim CVE-2026-34982.

## Not yet audited

Shell and process execution paths, modelines in general, and the msgpack-RPC API surface
(now only reachable with `--listen`). Dependency CVEs: see the section below.

## Dependency and upstream CVEs (checked 2026-11-01, rechecked 2026-11-03)

Method: web search of NVD/OSV/vendor advisories for each component that is compiled into
`wgvim` or shipped with it, then a check of this tree (version, patch list in
`src/nvim/version.c`, or the code itself). "Not affected" means the fix is in this tree or the
code path is not built. Re-check when updating `deps/`.

| Component (version in this tree) | Known CVEs | Status here |
|---|---|---|
| libuv 1.52.1 | CVE-2024-24806 (`uv_getaddrinfo` hostname truncation, fixed in 1.48.0); CVE-2014-9748 (Windows XP rwlock, fixed 1.7.4) | Not affected (newer version; `getaddrinfo` is also removed from Lua, row 6) |
| LuaJIT (commit `ea9eb7e`, 2026-10-30) | CVE-2024-25176, -25177, -25178 (fixed upstream early 2024); CVE-2020-24372, CVE-2020-15890 (2.1.0-beta3); CVE-2019-19391 (`debug.getinfo`, disputed by upstream) | Not affected by the fixed ones (commit is from 2026). CVE-2019-19391 is in the `debug` library, which Lua code can always reach; it needs code already running in the editor |
| luv 1.52.1-0 | None found | — |
| lua-compat-5.3 0.13 | None found | — |
| tree-sitter 0.27.1 | Distribution advisories in 2026 concern Wasmtime (CVE-2026-34971 sandbox escape on aarch64, CVE-2026-27204 WASI DoS) | Not affected: Wasmtime is not built (`ENABLE_WASMTIME=OFF`) |
| tree-sitter parsers (c 0.24.2, cpp 0.23.4, lua, vim, vimdoc, query, diff, markdown) | None found | Hash-pinned (row 16) |
| utf8proc 2.12.0 | Old buffer overrun / recursion bugs fixed in 2.1.0 (no CVE IDs) | Not affected |
| unibilium 2.1.4 | None found (ncurses terminfo CVEs such as CVE-2023-29491 are in ncurses, not unibilium) | — |
| libvterm (in-tree, `src/vterm`) | None found for libvterm itself | — |
| xxd (in-tree, "2025-11-26") | CVE-2025-9390 (buffer overflow in `main`, fixed by Vim 9.1.1616) | Not affected (xxd is newer; 9.1.1616 is in the patch list) |
| Neovim code (snapshot `d299306`) | CVE-2026-11487 (`vim.secure.read` command injection via file name, Neovim ≤ 0.12.2, fix PR #39918); CVE-2019-12735 (modeline `:source!`, fixed 0.3.6); GHSA-6f9m-hj8h-xjgj (tree-sitter injections, 2023) | Not affected: the CVE-2026-11487 fix and its regression test (`secure_spec`, "#39914") are present |
| Vim code shared with Neovim | CVE-2026-45130 (spell file `read_compound`, 9.2.0450), CVE-2026-25749 (`get_tagfname`, 9.1.2132), CVE-2026-28418/28419 (Emacs tags, 9.2.0074/75), CVE-2026-28420 (terminal combining chars, 9.2.0076), CVE-2026-32249 (NFA regex, 9.2.0137), CVE-2025-22134 (9.1.1003), CVE-2024-43374 (9.1.0678), CVE-2026-28417 (netrw `scp://` injection, 9.2.0073) | All these patches are in the included-patch list; netrw remote access is also removed (row 9) |
| Vim-only features | CVE-2026-34714 (`tabpanel` `%{}` in modeline, 9.2.0272), CVE-2026-26269 (NetBeans), CVE-2026-34982 (modeline sandbox bypass via `'complete'`, `guitabtooltip`, `printheader`) | Not applicable: no `tabpanel`, NetBeans, GUI or printing in this tree; `'complete'` is already protected (`modelineexpr`) |
| Not built (vendored only) | Lua 5.1.5, gettext 0.20.1, libiconv 1.19, Wasmtime 48.0.1, uncrustify 0.83.0, win32yank | Not part of the binary on Linux; not checked |

Recheck 2026-11-03: one new advisory, CVE-2026-47162 (Vim netrw `s:NetrwBookHistSave()`
wrote directory names into `.netrwhist` without escaping quotes, so a crafted directory name
injected Vim script that ran when the history was next sourced; fixed in 9.2.0495). Not
affected: this tree writes the entries with `string()` (the fix), and under the sandbox the
history file, in `stdpath('data')`, is read-only. Ubuntu USN-8544-1 (July 2026) concerns the
2024 LuaJIT CVEs already listed. Nothing new for libuv, luv, tree-sitter, utf8proc, unibilium
or libvterm.

Also checked: CVE-2026-33412 (Vim `glob()` newline command injection, fixed in 9.2.0202) — the
patch is in the included list. The search covered public advisories only; there is no automated
SBOM scan.
