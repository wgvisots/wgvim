-- wgvim: vim.pack was removed from this editor.
--
-- The upstream implementation cloned and updated plugins with `git`, which needs
-- the network. This stub keeps the `vim.pack` name and the :packupdate / :packdel
-- commands defined (they live in the C source) but contains no network code.
--
-- Install plugins by placing them under a `pack/*/start/` or `pack/*/opt/`
-- directory on 'packpath' and loading them with |packadd| (see |packages|).

---@class vim.pack
local M = {}

local function disabled()
  error('wgvim: vim.pack is removed (it fetched plugins over the network); use :packadd with vendored plugins', 0)
end

M.add = disabled
M.update = disabled
M.del = disabled
M.get = disabled

--- No plugins are managed by vim.pack.
---@return string[]
function M._get_names()
  return {}
end

return M
