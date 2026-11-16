# Changelog

wgvim's own releases (`:help wgvim-version`). Each release says which Neovim snapshot it is
based on; Neovim's changes are in Neovim's own release notes, and NOTICE lists what wgvim
changes in it.

Versions follow [semantic versioning](https://semver.org) for what wgvim adds and restricts:
a new major version when a release can break a working config (for example, the sandbox starts
refusing something it allowed), a minor version for new features, a patch version for fixes,
updated dependencies or a newer Neovim base that changes nothing a config relies on.
`has('nvim-x.y')` and `vim.version()` stay Neovim's, so plugins keep working.

## 1.0.0

The first release with its own version number. Based on Neovim v0.13.0-dev, snapshot
d2993065640e (2026-10-31).

**No network access**
- Removed `vim.net`, the `http(s)://` buffer reader, `vim.pack`, spell file downloads,
  `--remote`/`--server`/`--remote-ui`, and the Python, Ruby, Perl and Node.js providers.
- RPC, `sockconnect()` and LSP use pipes, Unix-domain sockets and stdio only; `vim.uv` has
  no TCP, UDP or DNS. netrw works on local files only.

**Sandbox** (`:help wgvim-sandbox`; Linux 5.13+, RHEL 9.6+)
- Landlock, applied before any config runs, to wgvim and everything it starts: read-write
  in the current directory and the files named on the command line, read-only for system
  paths and your config, nothing else (`~/.ssh` included). On newer kernels also no TCP, and
  signals only between wgvim's own processes; no tracing of processes outside the sandbox.
- A seccomp system-call filter: Unix sockets only, no connecting to existing sockets (D-Bus,
  ssh-agent, gpg-agent), no System V IPC, io_uring, kernel keyrings or new namespaces, and no
  `TIOCSTI`/`TIOCLINUX` terminal input injection.
- Clipboard through a helper started before the sandbox (desktop) or OSC 52 (SSH); programs
  in `:terminal` cannot set the clipboard.
- An optional SELinux policy for RHEL that confines wgvim in its own domain.

**Restricted features**
- No RPC server unless asked for; `'exrc'` and `'modelineexpr'` always off; LuaJIT `ffi` and
  native Lua modules disabled; tree-sitter parsers loaded only from the install, after their
  SHA256 is checked; `lsp/*.lua` only from your config and `$VIMRUNTIME`.

**Added**
- Reading aids: rainbow brackets, a scope guide, highlighting of the symbol under the
  cursor, and a context line (`:help wgvim-reading`).
- Harper grammar and spell checking as a sandboxed language server, pinned and audited
  (`:help wgvim-harper`).
- `tablefmt` and `:TableFmt`: tabular C and C++ after clang-format (`:help wgvim-tablefmt`).
- A tree-sitter parser for C++, and C++ and MATLAB highlight queries.

**Build and security**
- Built only from vendored, SHA256-checked dependencies; the build refuses network URLs.
- Compiler and linker hardening (PIE, full RELRO, `_FORTIFY_SOURCE`, stack protector,
  stack-clash protection, CET, zero-initialised stack variables), dependencies included.
- Fuzzing of the terminal emulator, the terminal input parser, the tree-sitter runtime and
  parsers, and tablefmt, and fixes for what it found (SECURITY-AUDIT.md).

**Distribution**
- A relocatable tarball for RHEL 9 (x86_64), built and tested offline in UBI 9, with an SPDX
  SBOM, a SHA-256 checksum, a GitHub build attestation and a maintainer's signature
  (RELEASING.md). Install it in `/opt/wgvim` (INSTALL.md).
- `wgvim --version` shows wgvim's version, its commit and the Neovim snapshot;
  `has('wgvim-1.0')` tests wgvim's version.
