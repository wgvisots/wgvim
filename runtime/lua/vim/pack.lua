-- wgvim: vim.pack was removed from this editor.
--
-- The upstream implementation cloned and updated plugins with `git`, which needs
-- the network. This stub keeps the `vim.pack` name and the :packupdate / :packdel
-- commands defined (they live in the C source) but contains no network code.
--
-- Install plugins by placing them under a `pack/*/start/` or `pack/*/opt/`
-- directory on 'packpath' and loading them with |packadd| (see |packages|).

--- @brief
--- `vim.pack` (the built-in plugin manager) is REMOVED in wgvim. It downloaded and updated
--- plugins with `git`, which needs the network. Every function below raises an error, and
--- `:packupdate` / `:packdel` do nothing useful.
---
--- Install plugins by copying them (vendored, reviewed) into a `pack/*/start/` or
--- `pack/*/opt/` directory on 'packpath' and load optional ones with |:packadd|.
--- See |packages|.

local M = {}

local function disabled()
  error('wgvim: vim.pack is removed (it fetched plugins over the network); use :packadd with vendored plugins', 0)
end

--- Removed in wgvim; always raises an error. See |vim.pack|.
M.add = disabled
--- Removed in wgvim; always raises an error. See |vim.pack|.
M.update = disabled
--- Removed in wgvim; always raises an error. See |vim.pack|.
M.del = disabled
--- Removed in wgvim; always raises an error. See |vim.pack|.
M.get = disabled

--- No plugins are managed by vim.pack.
---@return string[]
function M._get_names()
  return {}
end

return M
