-- wgvim: clipboard under the sandbox (|wgvim-sandbox|).
--
-- The sandbox refuses connect(), so wl-copy, xclip and xsel cannot reach the display server
-- from the editor. Two replacements:
-- - helper: a process started before the sandbox runs the clipboard tool for us (local desktop);
-- - osc52: copy through the terminal with OSC 52 (SSH). Pasting returns what was last copied
--   here, because many terminals (mintty, used by Cygwin and Git Bash) cannot answer OSC 52
--   reads, and waiting for them stalls every paste. Paste text from the system clipboard with
--   the terminal's own paste instead.

local M = {}

--- @param reg string
--- @return fun(lines: string[], regtype: string)
function M.helper_copy(reg)
  return function(lines, regtype)
    -- Like the clipboard tools themselves: a linewise yank ends with a newline, so that pasting
    -- it back (split on newlines, ending in '') is linewise again.
    local text = table.concat(lines, '\n') .. (regtype == 'V' and '\n' or '')
    vim.api.nvim__sandbox_clipboard('copy', reg, text)
  end
end

--- @param reg string
--- @return fun(): string[]|0
function M.helper_paste(reg)
  return function()
    local ok, text = pcall(vim.api.nvim__sandbox_clipboard, 'paste', reg, '')
    if not ok then
      return 0
    end
    return vim.split(text, '\n', { plain = true })
  end
end

local last = {} ---@type table<string, {[1]: string[], [2]: string}>

--- @param reg string
--- @return fun(lines: string[], regtype: string)
function M.osc52_copy(reg)
  local copy = require('vim.ui.clipboard.osc52').copy(reg)
  return function(lines, regtype)
    last[reg] = { vim.deepcopy(lines), regtype }
    copy(lines)
  end
end

--- @param reg string
--- @return fun(): table|0
function M.osc52_paste(reg)
  return function()
    local l = last[reg]
    if l == nil then
      return { {}, 'v' }
    end
    return { vim.deepcopy(l[1]), l[2] }
  end
end

return M
