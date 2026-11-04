-- wgvim: the binary in the build tree finds the source tree's runtime without $VIMRUNTIME.
local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local describe, it, eq = t.describe, t.it, t.eq

describe('build-tree binary', function()
  it('uses the source runtime when $VIMRUNTIME is not set', function()
    local r = vim
      .system({
        n.nvim_prog,
        '--sandbox',
        'off',
        '--clean',
        '--headless',
        '-c',
        'lua io.stdout:write(vim.env.VIMRUNTIME, " ", tostring((pcall(require, "vim.diagnostic"))))',
        '-c',
        'qa!',
      }, {
        clear_env = true,
        env = { HOME = os.getenv('HOME'), PATH = os.getenv('PATH') },
        text = true,
      })
      :wait(30000)
    eq(t.paths.test_source_path .. '/runtime true', r.stdout)
  end)
end)
