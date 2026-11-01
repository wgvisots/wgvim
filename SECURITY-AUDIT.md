# wgvim network and security audit

Policy (set by the wgvim maintainers): the editor needs no network access.
Network functionality that is near-identical to what **Vim 8.2** already had may
stay after review; anything newer than Vim 8.2 is audited or removed.

Scope: code reachable from the editor itself. Out of scope, and impossible to
enforce from inside the editor: any program the editor can start (`:!curl`,
`jobstart()`, `vim.system()`, `:terminal`, LSP servers, remote-plugin hosts). For a
hard guarantee, run wgvim in a network-isolated container or network namespace.

Status: **PROPOSED** unless marked DONE. Nothing below has been changed yet except
where stated. Evidence is from reading this tree at the commit named in `NOTICE`.

## Findings

| # | Surface | Where | In Vim 8.2? | Proposed |
|---|---------|-------|-------------|----------|
| 1 | `vim.net.request()` (runs `curl`) and the `http(s)://` buffer reader | `runtime/lua/vim/net*`, `runtime/plugin/net.lua` | No | **Remove** |
| 2 | `vim.pack` (runs `git clone`/`fetch` for plugins) | `runtime/lua/vim/pack*`, `ftplugin/nvim-pack.lua` | No | **Remove**; add a local plugin directory instead |
| 3 | RPC server on TCP (`--listen host:port`, `serverstart()`, `v:servername`) | `src/nvim/event/socket.c`, `msgpack_rpc/server.c` | No (Vim 8.2 `+clientserver` is X11-only) | **Remove TCP**; keep Unix-domain sockets/pipes |
| 4 | `--remote-ui` / `--server host:port` TCP client for the TUI | `src/nvim/ui_client.c` | No | **Remove TCP** |
| 5 | LSP client connecting to a server over TCP (`vim.lsp.rpc.connect`) | `runtime/lua/vim/lsp/rpc.lua` | No LSP at all | **Remove TCP**; keep spawning a local server over stdio (needed for clangd) |
| 6 | Lua access to sockets through luv: `tcp_*`, `udp_*`, `getaddrinfo`, `getnameinfo` (33 functions) | vendored luv | No | **Remove** via a build-time patch, so the pinned tarball hash is unchanged |
| 7 | Spell-file auto-download (uses #1; default host `ftp.nluug.nl`) | `runtime/lua/nvim/spellfile.lua` | Yes (`spellfile.vim`, over netrw) | **Decision needed** |
| 8 | `sockconnect()` / `channel_connect()` TCP client | `src/nvim/channel.c`, `socket.c` | Yes (`ch_open("host:port")`) | **Decision needed** |
| 9 | netrw remote protocols (ftp, scp, sftp, rcp, rsync, dav, http via curl/wget) | `runtime/pack/dist/opt/netrw` | Yes | **Decision needed** |
| 10 | `vim.ui.open()` / `gx` (starts the system URL opener) | `runtime/lua/vim/ui.lua` | Yes (netrw `gx`) | Keep; it only starts a local program |
| 11 | `:checkhealth` runs `curl --version` | `runtime/lua/vim/health/health.lua` | No | Remove with #1 (no network use, but no purpose) |
| 12 | OSC 52 clipboard (writes an escape sequence to the terminal) | `runtime/plugin/osc52.lua` | No | Keep; local terminal output only |
| 13 | Telemetry / update checks / phone-home | whole tree | n/a | **None found** in the editor. (LSP protocol constants mention `telemetry/event`; that is for servers, which are out of scope.) |

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
