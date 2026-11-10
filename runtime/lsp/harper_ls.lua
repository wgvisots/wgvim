-- wgvim: Harper, a grammar and spell checker, as a language server (|wgvim-harper|).
-- Turn it on with:  vim.lsp.enable('harper_ls')
-- Change anything with vim.lsp.config('harper_ls', { ... }), which is merged into this.
--
-- Harper keeps its dictionaries, ignored lints and statistics in files. By default they are in
-- ~/.config/harper-ls and ~/.local/share/harper-ls, which the sandbox does not let it write, so
-- they are put in stdpath('state')/harper instead. A project's .harper-dictionary.txt works as
-- is.
local state = vim.fn.stdpath('state') .. '/harper'

--- @type vim.lsp.Config
return {
  -- Always over stdio: without --stdio, harper-ls listens on a TCP port. It runs with its
  -- address space limited (vim.g.wgvim_harper_memory_mb, default 1024), so that a document
  -- that makes it allocate without bound gets it stopped rather than slowing the machine.
  cmd = function(dispatchers, config)
    local mb = tonumber(vim.g.wgvim_harper_memory_mb) or 1024
    return vim.lsp.rpc.start({
      'sh',
      '-c',
      'ulimit -v "$1" && exec harper-ls --stdio',
      'harper-ls',
      tostring(mb * 1024),
    }, dispatchers, { cwd = config.root_dir })
  end,
  filetypes = {
    'markdown',
    'text',
    'gitcommit',
    'mail',
    'c',
    'cpp',
    'lua',
    'python',
    'sh',
    'rust',
    'go',
    'toml',
    'cmake',
    'html',
  },
  root_markers = { '.harper-dictionary.txt', '.git' },
  settings = {
    ['harper-ls'] = {
      userDictPath = state .. '/dictionary.txt',
      fileDictPath = state .. '/file_dictionaries',
      ignoredLintsPath = state .. '/ignored_lints',
      statsPath = state .. '/stats.txt',
    },
  },
}
