-- wgvim: clang-format + tablefmt for C and C++ (|wgvim-tablefmt|).
--   :TableFmt         format the buffer: clang-format, then tablefmt
--   :'<,'>TableFmt    the selected lines only
-- Settings (in init.lua, before or after this runs):
--   vim.g.tablefmt_gq = 1             gq uses tablefmt alone in C/C++ buffers
--   vim.g.tablefmt_on_save = 1        format C/C++ files on :w
--   vim.g.tablefmt_cmd = 'tablefmt --hug-commas'   (default: the tablefmt next to wgvim)
--   vim.g.tablefmt_clang_format = 'clang-format-18'
if vim.g.loaded_wgvim_tablefmt then
  return
end
vim.g.loaded_wgvim_tablefmt = true

vim.api.nvim_create_user_command('TableFmt', function(a)
  require('wgvim.tablefmt').format({ buf = 0, first = a.line1, last = a.line2 })
end, { range = '%', bar = true, desc = 'clang-format + tablefmt (:help wgvim-tablefmt)' })

local group = vim.api.nvim_create_augroup('wgvim.tablefmt', {})
local function on(v)
  return v == 1 or v == true
end

vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = { 'c', 'cpp' },
  desc = 'gq uses tablefmt (g:tablefmt_gq)',
  callback = function(ev)
    if on(vim.g.tablefmt_gq) then
      vim.bo[ev.buf].formatexpr = "v:lua.require'wgvim.tablefmt'.formatexpr()"
    end
  end,
})

vim.api.nvim_create_autocmd('BufWritePre', {
  group = group,
  desc = 'Format C/C++ on write (g:tablefmt_on_save)',
  callback = function(ev)
    local ft = vim.bo[ev.buf].filetype
    if on(vim.g.tablefmt_on_save) and (ft == 'c' or ft == 'cpp') then
      require('wgvim.tablefmt').format({ buf = ev.buf })
    end
  end,
})
