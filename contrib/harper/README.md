# Harper in wgvim

[Harper](https://writewithharper.com) is a grammar and spell checker. wgvim runs its language
server, `harper-ls`, inside the editor's sandbox (`:help wgvim-harper`). This directory holds
what wgvim uses to check the release it pins.

| File | What |
|---|---|
| `Cargo.lock` | The lock file of the pinned release, Harper 3.1.0 (tag `v3.1.0`, commit `d52aeac0a6de1cdb030b231705ab7e7e4e12e197`, 2026-11-06). It covers Harper's whole workspace, so it lists more crates than `harper-ls` contains. |
| `audit-ignore.txt` | RustSec advisories that `cargo audit` reports for that lock file and that wgvim accepts, each with the reason. CI fails on any other vulnerability. |
| `LICENSE` | Harper's license (Apache-2.0). |

The package itself, `deps/harper-linux-x64-3.1.0.vsix` (Harper's VS Code extension for
Linux x86-64, a zip with `extension/bin/harper-ls`), is pinned in `cmake.deps/deps.txt`
(`HARPER_VSIX_SHA256`, and `HARPER_LS_SHA256` for the binary inside it).

## Checks

- **Pins**: `scripts/install-harper.sh` installs `harper-ls` only if the package and the binary
  match their SHA-256; `:checkhealth wgvim` checks the installed binary again.
- **Binary vs lock file**: `scripts/check-harper.py` finds the crate versions compiled into
  `harper-ls` (Rust keeps their source paths) and requires each to be in `Cargo.lock`, so the
  audit below is about this binary. 3.1.0: 68 crate versions found, all in the lock file.
- **RustSec**: CI runs `cargo audit` on `Cargo.lock` on every push and weekly.
- **Sandbox**: `harper-ls` runs as a sandboxed language server, with no network, and with its
  address space limited (`g:wgvim_harper_memory_mb`, 1024 MB by default).

## Audit of 3.1.0 (2026-11-09)

The RustSec database had 28 findings for the lock file: 20 vulnerabilities, 7 unsound and
2 unmaintained crates. The binary is not stripped, so its symbol table shows which crates it
contains:

- In `harper-ls`: **pulldown-cmark 0.13.4**, RUSTSEC-2026-0414 and -0433. Harper parses
  Markdown with all extensions on, including wiki links, and a small crafted Markdown file
  then makes it use CPU and memory without bound. Denial of service of the language server
  only; mitigated by the memory limit and the sandbox, until a Harper release has
  pulldown-cmark 0.13.6 or later.
- Not in `harper-ls` (no symbols of the crate, nor of the functions the advisories name):
  zip (4 advisories), the C zstd library and its bindings (zstd, zstd-safe, zstd-sys;
  harper-ls uses ruzstd, a separate pure-Rust decoder, for its built-in thesaurus),
  rustls-webpki and webpki-roots (no TLS code at all), bincode, paste.

## Updating to a new Harper release

1. Put the new `.vsix` in `deps/`, and its SHA-256 and that of `extension/bin/harper-ls` in
   `cmake.deps/deps.txt` and `runtime/lua/wgvim/harper.lua` (a test checks that they agree).
2. Replace `Cargo.lock` with the release's (`git show vX.Y.Z:Cargo.lock` in Harper's
   repository) and run `scripts/check-harper.py deps/<file>.vsix`.
3. Run `cargo audit --file contrib/harper/Cargo.lock`, check each finding against the binary,
   and update `audit-ignore.txt`: drop what no longer applies, give a reason for anything new.
