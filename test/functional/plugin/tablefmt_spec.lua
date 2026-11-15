-- wgvim: clang-format + tablefmt (|wgvim-tablefmt|): the tablefmt program (src/tablefmt) and
-- the plugin (runtime/plugin/tablefmt.lua, runtime/lua/wgvim/tablefmt.lua).
local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local describe, it, eq, matches = t.describe, t.it, t.eq, t.matches
local before_each, after_each = t.before_each, t.after_each
local exec_lua, command, feed = n.exec_lua, n.command, n.feed

local src = t.paths.test_source_path .. '/src/tablefmt'
local tablefmt = vim.fs.dirname(n.nvim_prog) .. '/tablefmt'

--- A clang-format of version 18 or later (the .clang-format needs it), or nil.
local function clang_format()
  if vim.fn.executable('clang-format') == 0 then
    return nil
  end
  local v = vim.system({ 'clang-format', '--version' }, { text = true }):wait().stdout or ''
  local major = tonumber(v:match('version (%d+)'))
  return major and major >= 18 and 'clang-format' or nil
end

--- tablefmt run directly: what the plugin must produce.
local function tablefmt_cli(lines, args)
  local cmd = { tablefmt }
  vim.list_extend(cmd, args or {})
  local out = vim.system(cmd, { stdin = table.concat(lines, '\n') .. '\n' }):wait().stdout
  local l = vim.split(out, '\n', { plain = true })
  table.remove(l)
  return l
end

-- Already clang-formatted, as tablefmt expects.
local input = {
  'struct S {',
  '    double a{0.0};',
  '    std::int32_t bb{0};',
  '    std::string c{};',
  '};',
  '',
  'void f(S& s) {',
  '    me["a"] = s.a;',
  '    me["bb"] = s.bb;',
  '}',
}

describe('tablefmt', function()
  local dir

  before_each(function()
    n.clear()
    command('runtime plugin/tablefmt.lua') -- tests start without plugins
    dir = t.tmpname(false)
    vim.fn.mkdir(dir, 'p')
    t.skip(vim.fn.executable(tablefmt) == 0, 'tablefmt not built (no C++20 compiler)')
    exec_lua(function(lines, d)
      vim.api.nvim_buf_set_name(0, d .. '/a.cpp')
      vim.bo.filetype = 'cpp'
      vim.api.nvim_buf_set_lines(0, 0, -1, true, lines)
      vim.bo.modified = false
      -- clang-format stand-in: passes the text through (extra arguments become $0, $1, ...).
      vim.g.tablefmt_clang_format = { 'sh', '-c', 'cat' }
    end, input, dir)
  end)

  after_each(function()
    vim.fn.delete(dir, 'rf')
  end)

  local function lines()
    return n.api.nvim_buf_get_lines(0, 0, -1, true)
  end

  it('is built next to wgvim, and is the one the plugin runs', function()
    eq({ tablefmt }, exec_lua(function()
      return require('wgvim.tablefmt').tablefmt_cmd()
    end))
  end)

  it(':TableFmt formats the buffer like tablefmt does, and one u undoes it', function()
    command('TableFmt')
    eq(tablefmt_cli(input), lines())
    t.neq(input, lines())
    command('undo')
    eq(input, lines())
  end)

  it('keeps marks and extmarks on the lines that did not change', function()
    -- Line 6 (blank) and line 10 ("}") stay as they are.
    local r = exec_lua(function()
      local ns = vim.api.nvim_create_namespace('test')
      local id = vim.api.nvim_buf_set_extmark(0, ns, 9, 0, {})
      vim.api.nvim_buf_set_mark(0, 'a', 6, 0, {})
      vim.cmd('TableFmt')
      return {
        extmark = vim.api.nvim_buf_get_extmark_by_id(0, ns, id, {})[1],
        mark = vim.api.nvim_buf_get_mark(0, 'a')[1],
      }
    end)
    eq({ extmark = 9, mark = 6 }, r)
  end)

  it(":'<,'>TableFmt touches only the tables in the range", function()
    command('7,10TableFmt')
    local want = tablefmt_cli(input, { '--lines=7:10' })
    eq(want, lines())
    eq(input[2], lines()[2]) -- the struct, outside the range, is unchanged
  end)

  it('gq uses tablefmt with g:tablefmt_gq', function()
    exec_lua(function()
      vim.g.tablefmt_gq = 1
      vim.bo.filetype = 'cpp' -- FileType again
    end)
    eq("v:lua.require'wgvim.tablefmt'.formatexpr()", n.api.nvim_get_option_value('formatexpr', {}))
    feed('2GVjjgq')
    local want = tablefmt_cli({ input[2], input[3], input[4] })
    eq(want, n.api.nvim_buf_get_lines(0, 1, 4, true))
    eq(input[1], lines()[1])
    eq(vim.list_slice(input, 5), vim.list_slice(lines(), 5))
  end)

  it('formats on :w with g:tablefmt_on_save', function()
    n.api.nvim_set_var('tablefmt_on_save', 1)
    command('write')
    eq(tablefmt_cli(input), vim.fn.readfile(dir .. '/a.cpp'))
  end)

  it('reports a failing clang-format and leaves the buffer alone', function()
    n.api.nvim_set_var('tablefmt_clang_format', { 'sh', '-c', 'echo boom >&2; exit 3' })
    matches('tablefmt: sh failed: boom', t.pcall_err(command, 'TableFmt'))
    eq(input, lines())
    n.api.nvim_set_var('tablefmt_clang_format', 'no-such-clang-format')
    matches('tablefmt: no%-such%-clang%-format: ', t.pcall_err(command, 'TableFmt'))
    eq(input, lines())
  end)

  describe('with clang-format 18+', function()
    before_each(function()
      t.skip(not clang_format(), 'needs clang-format 18 or later')
    end)

    it('the regression tests pass (src/tablefmt/tests)', function()
      local r = vim
        .system({ src .. '/tests/run.sh', tablefmt, clang_format() }, { text = true })
        :wait(60000)
      eq(0, r.code, r.stdout .. r.stderr)
      matches('all tests passed', r.stdout)
    end)

    it(':TableFmt runs clang-format with the .clang-format of the file', function()
      vim.fn.writefile(vim.fn.readfile(src .. '/.clang-format'), dir .. '/.clang-format')
      exec_lua(function(file)
        vim.g.tablefmt_clang_format = nil
        vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.fn.readfile(file))
      end, src .. '/tests/cases/example.in.cpp')
      command('TableFmt')
      eq(vim.fn.readfile(src .. '/tests/cases/example.expected.cpp'), lines())
    end)
  end)
end)
