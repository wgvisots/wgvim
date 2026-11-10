-- wgvim: Harper support (|wgvim-harper|): the pins and the shipped language server config.
local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local describe, it, eq, ok, before_each = t.describe, t.it, t.eq, t.ok, t.before_each

describe('Harper', function()
  before_each(n.clear)

  it('pins agree between cmake.deps/deps.txt and wgvim.harper', function()
    local deps = t.read_file(t.paths.test_source_path .. '/cmake.deps/deps.txt')
    local function pin(name)
      return deps:match('\n' .. name .. ' (%S+)')
    end
    local pins = n.exec_lua(function()
      return require('wgvim.harper').pins
    end)
    eq(1, #pins)
    eq('deps/' .. pins[1].vsix, pin('HARPER_VSIX_URL'))
    eq(pins[1].vsix_sha256, pin('HARPER_VSIX_SHA256'))
    eq(pins[1].bin_sha256, pin('HARPER_LS_SHA256'))
  end)

  it('the shipped config runs harper-ls over stdio, memory-limited, files in the state dir', function()
    local r = n.exec_lua(function()
      vim.g.wgvim_harper_memory_mb = 512 -- before the config is first loaded, as from init.lua
      local c = vim.lsp.config.harper_ls
      return {
        cmd = c.cmd,
        settings = c.settings['harper-ls'],
        state = vim.fn.stdpath('state'),
        md = vim.tbl_contains(c.filetypes, 'markdown'),
        c = vim.tbl_contains(c.filetypes, 'c'),
      }
    end)
    eq({ 'sh', '-c', 'ulimit -v "$1" && exec harper-ls --stdio', 'harper-ls', '524288' }, r.cmd)
    for _, k in ipairs({ 'userDictPath', 'fileDictPath', 'ignoredLintsPath', 'statsPath' }) do
      ok(vim.startswith(r.settings[k], r.state .. '/harper/'), k .. ' in the state dir', r.settings[k])
    end
    ok(r.md and r.c)
  end)
end)
