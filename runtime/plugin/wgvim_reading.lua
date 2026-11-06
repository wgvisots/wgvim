-- wgvim: the :Reading command (|wgvim-reading|). Everything stays off until it is used, or
-- until require('wgvim.reading').setup() is called from the config.
if vim.g.loaded_wgvim_reading then
  return
end
vim.g.loaded_wgvim_reading = true

vim.api.nvim_create_user_command('Reading', function(a)
  -- Loading the module replaces this command with the real one.
  require('wgvim.reading')
  vim.cmd({ cmd = 'Reading', args = a.fargs })
end, {
  nargs = '*',
  desc = 'Turn wgvim reading aids on or off (:help wgvim-reading)',
  complete = function(_, line)
    require('wgvim.reading')
    return vim.fn.getcompletion(line, 'cmdline')
  end,
})
