-- wgvim: reading aids (|wgvim-reading|).
local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

local describe, it, before_each = t.describe, t.it, t.before_each
local eq, matches = t.eq, t.matches
local clear, exec_lua, command, feed = n.clear, n.exec_lua, n.command, n.feed

describe('reading aids', function()
  local screen

  before_each(function()
    clear()
    command('runtime plugin/wgvim_reading.lua') -- tests start without plugins
    screen = Screen.new(50, 6)
    -- Distinct, simple colours for the first levels, so the grid shows the level of each
    -- bracket; no other highlighting.
    exec_lua(function()
      vim.api.nvim_set_hl(0, 'WgvimRainbow1', { fg = 'Red' })
      vim.api.nvim_set_hl(0, 'WgvimRainbow2', { fg = 'Blue' })
      vim.api.nvim_set_hl(0, 'WgvimRainbow3', { fg = 'Green' })
      vim.api.nvim_set_hl(0, 'WgvimRainbow4', { fg = 'Magenta' })
      vim.api.nvim_set_hl(0, 'WgvimScope', { fg = 'Gray' })
    end)
    screen:add_extra_attr_ids({
      [100] = { foreground = Screen.colors.Red },
      [101] = { foreground = Screen.colors.Blue },
      [102] = { foreground = Screen.colors.Green },
      [103] = { foreground = Screen.colors.Magenta },
      [104] = { foreground = Screen.colors.Gray },
    })
  end)

  local function c_buffer(lines)
    exec_lua(function(l)
      vim.api.nvim_buf_set_lines(0, 0, -1, true, l)
      vim.bo.filetype = 'c'
      vim.treesitter.query.set('c', 'highlights', '') -- only the reading aids
      vim.treesitter.start(0, 'c')
    end, lines)
  end

  it('rainbow: colours brackets by nesting level, matching pairs alike', function()
    c_buffer({ 'int f(int a[2]) { return g((a[0])); }' })
    exec_lua(function()
      require('wgvim.reading').setup({ rainbow = true })
    end)
    screen:expect([[
      ^int f{100:(}int a{101:[}2{101:]}{100:)} {100:{} return g{101:(}{102:(}a{103:[}0{103:]}{102:)}{101:)}; {100:}}             |
      {1:~                                                 }|*4
                                                        |
    ]])
  end)

  it('rainbow: ignores brackets in strings and comments', function()
    c_buffer({ 'f("(", /* [ */ x);' })
    exec_lua(function()
      require('wgvim.reading').setup({ rainbow = true })
    end)
    screen:expect([[
      ^f{100:(}"(", /* [ */ x{100:)};                                |
      {1:~                                                 }|*4
                                                        |
    ]])
  end)

  it('rainbow: off by default, and :Reading toggles it', function()
    c_buffer({ 'f(a[1]);' })
    screen:expect([[
      ^f(a[1]);                                          |
      {1:~                                                 }|*4
                                                        |
    ]])
    command('Reading rainbow on')
    screen:expect([[
      ^f{100:(}a{101:[}1{101:]}{100:)};                                          |
      {1:~                                                 }|*4
                                                        |
    ]])
    command('Reading rainbow')
    screen:expect([[
      ^f(a[1]);                                          |
      {1:~                                                 }|*4
                                                        |
    ]])
  end)

  it('rainbow: recolours lines whose nesting changed by an edit elsewhere', function()
    c_buffer({ 'int m() {', '  return g(', '    h(1)', '  );', '}' })
    exec_lua(function()
      require('wgvim.reading').setup({ rainbow = true })
    end)
    screen:expect([[
      ^int m{100:()} {100:{}                                         |
        return g{101:(}                                       |
          h{102:(}1{102:)}                                          |
        {101:)};                                              |
      {100:}}                                                 |
                                                        |
    ]])
    -- Wrap the call in f( ... ): lines 2 and 4 change, line 3 only moves a level deeper.
    exec_lua(function()
      vim.api.nvim_buf_set_text(0, 1, 9, 1, 9, { 'f(' })
      vim.api.nvim_buf_set_text(0, 3, 2, 3, 2, { ')' })
    end)
    screen:expect([[
      ^int m{100:()} {100:{}                                         |
        return f{101:(}g{102:(}                                     |
          h{103:(}1{103:)}                                          |
        {102:)}{101:)};                                             |
      {100:}}                                                 |
                                                        |
    ]])
  end)

  it('scope: draws a line along the block around the cursor', function()
    c_buffer({ 'int f(void) {', '    if (x) {', '        y();', '    }', '}' })
    exec_lua(function()
      require('wgvim.reading').setup({ scope = true })
    end)
    feed('3G')
    screen:expect([[
      int f(void) {                                     |
          if (x) {                                      |
          {104:│}   ^y();                                      |
          }                                             |
      }                                                 |
                                                        |
    ]])
    feed('2G')
    screen:expect([[
      int f(void) {                                     |
      {104:│}   ^if (x) {                                      |
      {104:│}       y();                                      |
      {104:│}   }                                             |
      }                                                 |
                                                        |
    ]])
  end)

  it('scope: block detection', function()
    local lines = { 'a', '  b', '', '    c', '  d', 'e' }
    local r = exec_lua(function(l)
      vim.api.nvim_buf_set_lines(0, 0, -1, true, l)
      local s = require('wgvim.reading')._scope_at
      return { { s(0, 2) }, { s(0, 4) }, { s(0, 1) }, { s(0, 3) } }
    end, lines)
    eq({ 1, 4, 0 }, r[1]) -- "b": rows 1-4, opened by "a" at column 0
    eq({ 3, 3, 2 }, r[2]) -- "c": row 3, opened by "b" at column 2
    eq({}, r[3]) -- "a": top level, no block
    eq({ 3, 3, 2 }, r[4]) -- blank line: the block of the next line
  end)

  it('references: highlights the word under the cursor without a language server', function()
    exec_lua(function()
      vim.api.nvim_buf_set_lines(0, 0, -1, true, { 'foo = 1', 'bar = foo + foobar' })
      vim.api.nvim_set_hl(0, 'WgvimReference', { fg = 'Red' })
      vim.o.updatetime = 50
      require('wgvim.reading').setup({ references = true })
    end)
    feed('gg')
    n.poke_eventloop()
    exec_lua(function()
      vim.api.nvim_exec_autocmds('CursorHold', {})
    end)
    screen:expect([[
      {100:^foo} = 1                                           |
      bar = {100:foo} + foobar                                |
      {1:~                                                 }|*3
                                                        |
    ]])
    feed('j')
    screen:expect([[
      foo = 1                                           |
      ^bar = foo + foobar                                |
      {1:~                                                 }|*3
                                                        |
    ]])
  end)

  describe('context', function()
    local c_lines = {
      'int f(void) {',
      '    if (x) {',
      '        a();',
      '        b();',
      '        c();',
      '        d();',
      '        e();',
      '    }',
      '}',
    }
    before_each(function()
      exec_lua(function()
        vim.api.nvim_set_hl(0, 'WgvimContext', { bg = 'LightGrey' })
        vim.api.nvim_set_hl(0, 'WgvimContextBottom', { underline = true })
      end)
    end)

    it('shows the first lines of the blocks scrolled off the top', function()
      c_buffer(c_lines)
      exec_lua(function()
        require('wgvim.reading').setup({ context = true })
      end)
      feed('4Gzt7G')
      screen:add_extra_attr_ids({ [105] = { background = Screen.colors.LightGrey } })
      screen:expect([[
        {105:int f(void) {                                     }|
        {24:    if (x) {                                      }|
                d();                                      |
                ^e();                                      |
            }                                             |
                                                          |
      ]])
      -- Scrolled back to the top: nothing is hidden, no context.
      feed('gg')
      screen:expect([[
        ^int f(void) {                                     |
            if (x) {                                      |
                a();                                      |
                b();                                      |
                c();                                      |
                                                          |
      ]])
    end)

    it('keeps rainbow colours', function()
      c_buffer(c_lines)
      exec_lua(function()
        require('wgvim.reading').setup({ context = true, rainbow = true })
      end)
      feed('4Gzt7G')
      screen:add_extra_attr_ids({
        [101] = { foreground = Screen.colors.Blue },
        [102] = { foreground = Screen.colors.Green },
        [105] = { background = Screen.colors.LightGray },
        [106] = { foreground = Screen.colors.Red, background = Screen.colors.LightGray },
        [107] = {
          foreground = Screen.colors.Blue1,
          underline = true,
          background = Screen.colors.LightGray,
        },
      })
      screen:expect([[
        {105:int f}{106:(}{105:void}{106:)}{105: }{106:{}{105:                                     }|
        {24:    if }{107:(}{24:x}{107:)}{24: }{107:{}{24:                                      }|
                d{102:()};                                      |
                ^e{102:()};                                      |
            {101:}}                                             |
                                                          |
      ]])
    end)

    it('hides while the cursor is on a line it would cover', function()
      c_buffer(c_lines)
      exec_lua(function()
        require('wgvim.reading').setup({ context = true })
      end)
      feed('5Gzt')
      screen:expect([[
                ^c();                                      |
                d();                                      |
                e();                                      |
            }                                             |
        }                                                 |
                                                          |
      ]])
    end)

    it('works from indentation without a parser, with line numbers', function()
      exec_lua(function()
        vim.api.nvim_buf_set_lines(0, 0, -1, true, {
          'def f():',
          '    for x in y:',
          '        a()',
          '        b()',
          '        c()',
          '        d()',
        })
        vim.wo.number = true
        require('wgvim.reading').setup({ context = true })
      end)
      feed('3Gzt6G')
      screen:add_extra_attr_ids({
        [105] = { background = Screen.colors.LightGrey, foreground = Screen.colors.Brown },
        [106] = { background = Screen.colors.LightGrey },
        [107] = {
          underline = true,
          background = Screen.colors.LightGrey,
          foreground = Screen.colors.Brown,
        },
      })
      screen:expect([[
        {105:  1 }{106:def f():                                      }|
        {107:  2 }{24:    for x in y:                               }|
        {8:  5 }        c()                                   |
        {8:  6 }        ^d()                                   |
        {1:~                                                 }|
                                                          |
      ]])
    end)

    it('context_jump() goes to the innermost context line', function()
      c_buffer(c_lines)
      exec_lua(function()
        require('wgvim.reading').setup({ context = true })
      end)
      feed('4Gzt7G')
      n.poke_eventloop()
      exec_lua(function()
        require('wgvim.reading').context_jump()
      end)
      eq({ 2, 4 }, n.api.nvim_win_get_cursor(0))
    end)
  end)

  it(':Reading reports the state and rejects unknown names', function()
    matches('rainbow: off, scope: off, references: off, context: off', n.exec_capture('Reading'))
    command('Reading scope on')
    matches('scope: on', n.exec_capture('Reading'))
    command('Reading colour on')
    matches('unknown feature: colour', n.exec_capture('messages'))
  end)
end)
