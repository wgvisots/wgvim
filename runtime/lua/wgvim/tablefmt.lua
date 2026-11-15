-- wgvim: clang-format + tablefmt for C and C++ buffers (|wgvim-tablefmt|).
--
-- tablefmt (src/tablefmt) aligns runs of similar lines into tables after clang-format. Both
-- run as programs, without a shell, with the buffer on stdin. Their result is applied as the
-- lines that changed, not as a new buffer, so marks, extmarks (diagnostics, signs) and folds on
-- the lines that did not change stay where they were, and one |u| undoes it all.
local M = {}

local api = vim.api

--- A command from a setting: a list, or a string split at whitespace ("tablefmt --hug-commas").
--- @param v string|string[]|nil
--- @param default string
--- @return string[]
local function cmdlist(v, default)
  if type(v) == 'table' then
    return vim.deepcopy(v)
  end
  if type(v) == 'string' and vim.trim(v) ~= '' then
    return vim.split(vim.trim(v), '%s+')
  end
  return { default }
end

--- The tablefmt command: g:tablefmt_cmd, else the tablefmt installed next to wgvim, else
--- "tablefmt" from $PATH.
--- @return string[]
function M.tablefmt_cmd()
  local v = vim.g.tablefmt_cmd
  if v ~= nil and v ~= '' then
    return cmdlist(v, 'tablefmt')
  end
  local beside = vim.fs.joinpath(vim.fs.dirname(vim.v.progpath), 'tablefmt')
  if vim.fn.executable(beside) == 1 then
    return { beside }
  end
  return { 'tablefmt' }
end

--- The clang-format command: g:tablefmt_clang_format, else "clang-format".
--- @return string[]
function M.clang_format_cmd()
  return cmdlist(vim.g.tablefmt_clang_format, 'clang-format')
end

--- Runs `cmd` with `input` on stdin.
--- @return string? stdout, string? error
local function run(cmd, input)
  local ok, obj = pcall(vim.system, cmd, { stdin = input, text = true })
  if not ok then
    return nil, ('%s: %s'):format(cmd[1], tostring(obj):gsub('^.-: ', ''))
  end
  local r = obj:wait(10000)
  if r.code ~= 0 then
    local msg = vim.trim(r.stderr or '')
    if msg == '' then
      msg = r.signal ~= 0 and ('signal %d'):format(r.signal) or ('exit %d'):format(r.code)
    end
    return nil, ('%s failed: %s'):format(vim.fs.basename(cmd[1]), msg:match('[^\n]*'))
  end
  return r.stdout
end

local function err(msg)
  vim.notify('tablefmt: ' .. msg, vim.log.levels.ERROR)
end

local function lines_of(text)
  local l = vim.split(text, '\n', { plain = true })
  if l[#l] == '' then
    table.remove(l)
  end
  return l
end

--- Replaces lines `offset+1 ..` of `buf` (now `old`) by `new`, changing only the lines that
--- differ.
--- @return boolean changed
local function apply(buf, offset, old, new)
  if vim.deep_equal(old, new) then
    return false
  end
  local a = table.concat(old, '\n') .. '\n'
  local b = table.concat(new, '\n') .. '\n'
  local hunks = vim.text.diff(a, b, { result_type = 'indices', algorithm = 'histogram' })
  --- @cast hunks integer[][]
  local wins = vim.fn.win_findbuf(buf)
  local views = {}
  for _, w in ipairs(wins) do
    views[w] = api.nvim_win_call(w, vim.fn.winsaveview)
  end
  -- Last hunk first, so the line numbers of the earlier ones still hold.
  for i = #hunks, 1, -1 do
    local sa, ca, sb, cb = unpack(hunks[i])
    local start = offset + (ca == 0 and sa or sa - 1)
    api.nvim_buf_set_lines(buf, start, start + ca, false, vim.list_slice(new, sb, sb + cb - 1))
  end
  for w, view in pairs(views) do
    api.nvim_win_call(w, function()
      vim.fn.winrestview(view)
    end)
  end
  return true
end

--- @class wgvim.tablefmt.Opts
--- @field buf? integer
--- @field first? integer first line (1-based), default 1
--- @field last? integer last line, default the last one
--- @field clang_format? boolean run clang-format first (default true)

--- Formats lines `first`..`last` of a buffer (all of it by default): clang-format, then
--- tablefmt, both limited to those lines when not the whole buffer.
--- @param opts? wgvim.tablefmt.Opts
--- @return boolean changed
function M.format(opts)
  opts = opts or {}
  local buf = opts.buf
  if buf == nil or buf == 0 then
    buf = api.nvim_get_current_buf()
  end
  local old = api.nvim_buf_get_lines(buf, 0, -1, false)
  local first, last = opts.first or 1, opts.last or #old
  local range = (first == 1 and last == #old) and {}
    or { ('--lines=%d:%d'):format(first, last) }
  local text = table.concat(old, '\n') .. '\n'
  if opts.clang_format ~= false then
    local name = api.nvim_buf_get_name(buf)
    if name == '' then
      -- clang-format picks the language, and looks for .clang-format, from this name.
      name = vim.bo[buf].filetype == 'c' and 'stdin.c' or 'stdin.cpp'
    end
    local cf = M.clang_format_cmd()
    vim.list_extend(cf, { '--assume-filename=' .. name })
    vim.list_extend(cf, range)
    local e
    text, e = run(cf, text)
    if not text then
      err(e)
      return false
    end
  end
  local tf = M.tablefmt_cmd()
  vim.list_extend(tf, range)
  local out, e = run(tf, text)
  if not out then
    err(e)
    return false
  end
  return apply(buf, 0, old, lines_of(out))
end

--- 'formatexpr' for |gq| (set with g:tablefmt_gq): tablefmt alone on the lines, as with
--- 'formatprg', but without a shell and changing only the lines that differ. While typing
--- ('textwidth' wrapping), Vim's own formatting is used.
--- @return integer
function M.formatexpr()
  if vim.v.char ~= '' then
    return 1
  end
  local buf = api.nvim_get_current_buf()
  local first = vim.v.lnum
  local last = first + vim.v.count - 1
  local old = api.nvim_buf_get_lines(buf, first - 1, last, false)
  local out, e = run(M.tablefmt_cmd(), table.concat(old, '\n') .. '\n')
  if not out then
    err(e)
    return 0
  end
  apply(buf, first - 1, old, lines_of(out))
  return 0
end

return M
