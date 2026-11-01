# wgvim

wgvim is a modified version of [Neovim](https://neovim.io), kept for use on
machines that must not reach the network.

**This is not the Neovim project.** Almost everything here was written by the
Neovim contributors and, before them, the Vim contributors, and the credit for it
is theirs. See [NOTICE](NOTICE) for the origin, the list of changes and the
licence terms, and [LICENSE.txt](LICENSE.txt) for the licence itself. Please do
not report wgvim problems to the Neovim project.

## What differs from Neovim

- Builds only from vendored, hash-checked dependencies in [deps/](deps/); the
  build refuses network URLs.
- The executable, config/data/cache directories and environment variables are
  named `wgvim` / `WGVIM` (for example `~/.config/wgvim`).
- No Zig build, CI configuration or network-publishing scripts.
- Tree-sitter parsers for C and C++ are built in the same way as the others.

## Building

Requirements: a C compiler, CMake, and Ninja or Make. No network access is used.

```sh
scripts/verify-deps.sh          # check deps/ against the pinned SHA256 hashes
make CMAKE_BUILD_TYPE=Release   # builds the dependencies, then build/bin/wgvim
VIMRUNTIME=runtime ./build/bin/wgvim
```

For a build with a hard guarantee that nothing touches the network, run it in a
network-isolated container, or with `unshare -n` on Linux.

See [BUILD.md](BUILD.md) for options and [INSTALL.md](INSTALL.md) for installing.
