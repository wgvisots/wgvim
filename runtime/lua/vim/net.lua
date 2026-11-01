-- wgvim: network access was removed from this editor.
--
-- The upstream implementation of vim.net.request() ran `curl`. This stub keeps the
-- `vim.net` name defined (other code refers to it) but contains no network code.

---@class vim.net
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
