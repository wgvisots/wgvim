-- wgvim: ":syntax iskeyword" replaces the previous value instead of adding to it.
local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local describe, it, before_each = t.describe, t.it, t.before_each
local clear, exec, eq = n.clear, n.exec, t.eq

describe(':syntax iskeyword', function()
  before_each(clear)

  local function syn_at_start()
    return n.eval('synIDattr(synID(1, 1, 1), "name")')
  end

  it('replaces the characters of an earlier :syntax iskeyword', function()
    exec([[
      call setline(1, 'NOTE: text')
      syntax keyword TestMark NOTE
      syntax iskeyword @,48-57,_,:
    ]])
    -- With ":" a keyword character, "NOTE:" is one word and does not match.
    eq('', syn_at_start())
    exec('syntax iskeyword @,48-57,_')
    eq('TestMark', syn_at_start())
  end)

  it('keeps tutor keywords when sh.vim is included for bash', function()
    clear({ args = { '--clean' } })  -- as tutor_spec.lua: syntax highlighting on
    exec([[
      let g:is_bash = 1
      Tutor
      call search('^NOTE')
    ]])
    eq('tutorMarks', n.eval('synIDattr(synID(line("."), 1, 1), "name")'))
  end)
end)
