-- wgvim: network access was removed from this editor.
--
-- The upstream implementation of vim.net.request() ran `curl`. This stub keeps the
-- `vim.net` name defined (other code refers to it) but contains no network code.

--- @brief
--- `vim.net` is REMOVED in wgvim: the editor makes no network requests. |vim.net.request()|
--- always raises an error, and URLs opened with |:edit| are not downloaded.

local M = {}

--- Always fails: network requests are disabled in wgvim.
---@param method string
---@param url string
---@param opts? table
---@param on_response? function
function M.request(method, url, opts, on_response) -- luacheck: ignore
  error('wgvim: network requests are disabled (vim.net.request)', 0)
end

return M
