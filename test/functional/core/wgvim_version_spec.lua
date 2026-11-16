-- wgvim's own version (|wgvim-version|): "wgvim --version" and :version show it, the Neovim
-- snapshot it is based on, and the commit; vim.version() stays Neovim's.
local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local describe, it, eq, matches = t.describe, t.it, t.eq, t.matches

--- The wgvim version set in CMakeLists.txt ("1.0.0", "1.0.1-dev").
local function cmake_version()
  local src = table.concat(vim.fn.readfile(t.paths.test_source_path .. '/CMakeLists.txt'), '\n')
  local function get(k)
    return src:match('set%(WGVIM_VERSION_' .. k .. ' "?([^")]*)"?%)')
  end
  return ('%s.%s.%s%s'):format(get('MAJOR'), get('MINOR'), get('PATCH'), get('PRERELEASE'))
end

describe('wgvim version', function()
  it('--version: wgvim version and commit, then the Neovim snapshot', function()
    local out = vim.system({ n.nvim_prog, '--version' }, { text = true }):wait().stdout
    local l = vim.split(out, '\n')
    local v = cmake_version()
    -- The commit is there when the build knows it (git, or a "git archive").
    matches('^WGVIM v' .. vim.pesc(v) .. ' %(commit %x%x%x%x%x%x%x+%-?%a*%)$', l[1])
    n.clear()
    local nv = n.exec_lua(function()
      return vim.version()
    end)
    eq(
      ('Based on Neovim v%d.%d.%d%s (snapshot %s), see NOTICE'):format(
        nv.major,
        nv.minor,
        nv.patch,
        nv.prerelease and '-' .. nv.prerelease or '',
        'd299306'
      ),
      l[2]
    )
  end)

  it(':version shows the same first line', function()
    n.clear()
    local out = vim.system({ n.nvim_prog, '--version' }, { text = true }):wait().stdout
    matches('^' .. vim.pesc(vim.split(out, '\n')[1]) .. '\n', n.exec_capture('version') .. '\n')
  end)

  it('vim.version() is still Neovim\'s, and names the wgvim commit as its build', function()
    n.clear()
    local r = n.exec_lua(function()
      return { v = vim.version(), long = vim.fn.execute('version') }
    end)
    t.neq(1, r.v.major) -- not wgvim's 1.x
    local commit = r.long:match('%(commit (%x+[%-%a]*)%)')
    eq(commit, r.v.build)
  end)
end)
