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
| 14 | LuaJIT `ffi`: Lua can call libc directly, including `socket()`/`connect()` | built into LuaJIT; nothing in `runtime/` or `src/` uses it | No | **Decision needed**: it can be disabled after `luaL_openlibs` (`src/nvim/lua/executor.c`); only third-party plugins that use `ffi` would break |

## Limits of what the editor can enforce

Removing the network API closes the *ordinary* routes, but Lua code running inside
the editor is a full programming environment. Tested on the final build:

- `uv.new_tcp`, `uv.new_udp` and `uv.getaddrinfo` are gone, but through LuaJIT's `ffi`
  a script can still call `socket()` (row 14).
- `io.popen`, `os.execute`, `:!`, `jobstart()` and `vim.system()` start other programs,
  which have their own network access.

So these changes remove accidental and built-in network use; they are **not** a
sandbox. Treat plugins and any `init.lua` as trusted code, and enforce "no network"
at the OS level (network namespace, container without a network, or firewall rule).

## Related findings (not network)

- **Parsers are loaded from `parser/*.so` on the runtimepath.** Any directory on
  `runtimepath` can therefore execute native code in the editor. Audit where the
  runtimepath is built from and what is writable.
- Dead `ZIG_BUILD` branches remain in `cmake.config/versiondef.h.in` and
  `src/nvim/os/lang.c`; docs still describe removed scripts (`MAINTAIN.md`,
  `runtime/doc/dev_vimpatch.txt`).

## Not yet audited

Shell and process execution paths, modelines and `exrc`/secure mode, temp-file
handling, the msgpack-RPC API surface, vendored dependency versions against known
CVEs, and compiler hardening flags. Test suites have not been run on the renamed tree.
