local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local describe, it, before_each = t.describe, t.it, t.before_each
local eq = t.eq
local retry = t.retry

local clear = n.clear
local fn = n.fn
local testprg = n.testprg
local exec_lua = n.exec_lua
local eval = n.eval

describe(':terminal', function()
  before_each(function()
    clear()

    exec_lua([[
      local function clipboard(reg, type)
        if type == 'copy' then
          return function(lines)
            vim.g.clipboard_lines = lines
            local data = table.concat(lines, '\n')
            vim.g.clipboard_data = data
          end
        end

        if type == 'paste' then
          return function()
            error()
          end
        end

        error('invalid type: ' .. type)
      end

      vim.g.clipboard = {
        name = 'Test',
        copy = {
          ['+'] = clipboard('+', 'copy'),
          ['*'] = clipboard('*', 'copy'),
        },
        paste = {
          ['+'] = clipboard('+', 'paste'),
          ['*'] = clipboard('*', 'paste'),
        },
      }
    ]])
  end)

  local function osc52(arg)
    return string.format('\027]52;;%s\027\\', arg)
  end

  -- wgvim: programs running in :terminal cannot set the system clipboard (OSC 52 is ignored
  -- for the clipboard and only surfaces as a TermRequest event). See SECURITY-AUDIT.md.
  it('does not let a terminal program write to the system clipboard', function()
    eq('Test', eval('g:clipboard.name'))
    exec_lua(function()
      _G.osc52_requests = 0
      vim.api.nvim_create_autocmd('TermRequest', {
        callback = function(ev)
          if ev.data.sequence:find('^\027%]52;') then
            _G.osc52_requests = _G.osc52_requests + 1
          end
        end,
      })
    end)

    local encoded = exec_lua('return vim.base64.encode(...)', 'pasted from a terminal program')
    fn.jobstart({ testprg('shell-test'), '-t', osc52(encoded) }, { term = true })

    -- The sequence reaches the editor (as a TermRequest)...
    retry(nil, 1000, function()
      eq(1, exec_lua('return _G.osc52_requests'))
    end)
    -- ...but the clipboard provider was never called.
    eq(vim.NIL, exec_lua([[ return vim.g.clipboard_data ]]))
  end)
end)
