# wgvim

[![CI](https://github.com/wgvisots/wgvim/actions/workflows/ci.yml/badge.svg)](https://github.com/wgvisots/wgvim/actions/workflows/ci.yml)

wgvim is an offline, hardened build of [Neovim](https://neovim.io) for machines
that must not reach the network. The editor makes no network connections, loads
no code from outside its install and your own config, and is built with
compiler and linker hardening. It targets Linux; RHEL 9 is the main platform.

**This is not the Neovim project.** Almost everything here was written by the
Neovim contributors and, before them, Bram Moolenaar and the Vim contributors,
and the credit for it is theirs. wgvim only removes and restricts features. See
[NOTICE](NOTICE) for the origin, the list of changes and the licence terms, and
[LICENSE.txt](LICENSE.txt) for the licence itself. Please do not report wgvim
problems to the Neovim project.

## What differs from Neovim

Inside the editor, `:help wgvim` has the full list. In short:

**No network access**
- `vim.net`, the `http(s)://` buffer reader and `vim.pack` (which used `git`)
  are removed. Install plugins by copying them into a `pack/*/start/` or
  `pack/*/opt/` directory.
- Spell files are not downloaded; English is bundled.
- netrw works only on local files.
- RPC servers, `sockconnect()` and LSP clients use only pipes, Unix-domain
  sockets and stdio, never TCP. `vim.uv` has no TCP, UDP or DNS functions.
- Programs you start yourself (`:!`, `:terminal`, jobs, LSP servers) are not
  restricted. For a hard guarantee, run wgvim without network access at the
  operating-system level.

**Sandbox**
- At startup, before any config or plugin runs, wgvim confines itself and
  everything it starts (`:!`, `:terminal`, LSP servers such as clangd) with
  Landlock: read-write in the current directory and in files named on the
  command line, read-only for system paths and your config, and no TCP.
  Nothing else, `~/.ssh` included, can be read or written. See
  `:help wgvim-sandbox`; it needs Linux 5.13+ (RHEL 9.6+).

**Restricted features**
- No RPC server is started at startup unless you pass `--listen` or call
  `serverstart()`.
- `'exrc'` and `'modelineexpr'` are always off and cannot be turned on (E519).
- LuaJIT's `ffi` library is disabled, and native Lua modules (`.so`) cannot be
  loaded.
- Tree-sitter parsers are loaded only from the install directory, and only the
  ones bundled at build time, after their SHA256 is checked.
- `lsp/*.lua` configs are read only from your config directory and `$VIMRUNTIME`.
- Programs running in `:terminal` cannot set the system clipboard (OSC 52).
- The Python, Ruby, Perl and Node.js providers and remote plugins are removed.
  The clipboard provider stays.

**Build and names**
- Built only from vendored, hash-checked dependencies in [deps/](deps/); the
  build refuses network URLs.
- Hardened build: PIE, full RELRO, `_FORTIFY_SOURCE`, stack protector,
  stack-clash protection, CET (`-fcf-protection`), zero-initialised stack
  variables, non-executable stack. The dependencies are hardened too.
- Bugs found by fuzzing the terminal emulator and the terminal input parser are
  fixed (see [SECURITY-AUDIT.md](SECURITY-AUDIT.md)).
- The executable, config/data/cache directories and environment variables are
  named `wgvim` / `WGVIM` (for example `~/.config/wgvim` and `$WGVIM_LOG_FILE`).
  Internal names that plugins rely on (the `nvim_*` API, the `vim` Lua module)
  are unchanged, so most Neovim plugins work as they are.

## Building

Requirements: a C compiler (GCC 11 or later, or Clang), CMake 3.16 or later,
gettext, and Ninja or Make. The build does not use the network.

```sh
scripts/verify-deps.sh          # check deps/ against the pinned SHA256 hashes
make CMAKE_BUILD_TYPE=Release   # builds the dependencies, then build/bin/wgvim
VIMRUNTIME=runtime ./build/bin/wgvim
sudo make install               # installs to /usr/local (see INSTALL.md)
```

For a hard guarantee that nothing touches the network during the build, build
in a network-isolated container (as below), or with `unshare -n` on Linux.

See [BUILD.md](BUILD.md) for options and [INSTALL.md](INSTALL.md) for installing.

## Testing

```sh
scripts/check-hardening.sh      # check the hardening of build/bin/wgvim
scripts/smoke-test.sh           # check the restrictions above on a built binary
cmake --build build --target functionaltest   # run as a non-root user
make oldtest                    # the Vim test suite
```

- **RHEL 9:** `scripts/rhel9-container-test.sh` (podman or docker) builds and
  tests wgvim in a Red Hat UBI 9 container. The container runs with
  `--network none`, uses RHEL's own GCC 11, and runs the tests as a non-root
  user. Results go to `rhel9-results/<timestamp>/summary.txt`.
- **Fuzzing:** [test/fuzz/README.md](test/fuzz/README.md) has the libFuzzer
  harnesses for the terminal emulator and the terminal input parser.
- **CI:** [.github/workflows/ci.yml](.github/workflows/ci.yml) runs on every
  push to `master` and every pull request:
  - Ubuntu 24.04 builds with GCC and Clang
  - the RHEL 9 container script
  - both fuzzers, for 5 minutes each (30 minutes on a weekly run)
- **Coverage:** [COVERAGE.md](COVERAGE.md) has the latest coverage report.

## Security

[SECURITY-AUDIT.md](SECURITY-AUDIT.md) records what was reviewed, what was
changed and why, the fuzzing results, and the known CVEs in the bundled
dependencies.
