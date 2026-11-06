-- wgvim: reading aids (|wgvim-reading|).
--
-- - rainbow: colour each nesting level of (), [] and {} differently, from the treesitter tree
--   (brackets in strings and comments are not part of the tree's bracket nodes, so they are
--   left alone);
-- - scope: draw a thin vertical line along the block the cursor is in;
-- - references: highlight other uses of the name under the cursor (LSP documentHighlight when
--   a language server provides it, otherwise the word under the cursor in the window).
--
-- Everything is off until setup() or :Reading turns it on.

local api = vim.api

local M = {}

-- Ephemeral extmarks are only drawn in the decoration provider's own namespace.
local ns = api.nvim_create_namespace('wgvim.reading')
local augroup = api.nvim_create_augroup('wgvim.reading', { clear = true })

--- @class wgvim.reading.Opts
--- @field rainbow? boolean
--- @field scope? boolean
--- @field references? boolean
--- @field scope_char? string Character drawn by the scope guide (default "│").

local state = {
  rainbow = false,
  scope = false,
  references = false,
  scope_char = '│',
}

M.levels = 7

-- Okabe–Ito: distinguishable with the common forms of colour blindness.
local palette = {
  { gui = '#E69F00', cterm = 214 }, -- orange
  { gui = '#56B4E9', cterm = 74 }, -- sky blue
  { gui = '#009E73', cterm = 36 }, -- bluish green
  { gui = '#F0E442', cterm = 227 }, -- yellow
  { gui = '#CC79A7', cterm = 175 }, -- reddish purple
  { gui = '#D55E00', cterm = 166 }, -- vermillion
  { gui = '#0072B2', cterm = 25 }, -- blue
}

local function set_default_highlights()
  for i, c in ipairs(palette) do
    api.nvim_set_hl(0, 'WgvimRainbow' .. i, { fg = c.gui, ctermfg = c.cterm, default = true })
  end
  api.nvim_set_hl(0, 'WgvimScope', { link = 'Comment', default = true })
  api.nvim_set_hl(0, 'WgvimReference', { link = 'LspReferenceText', default = true })
end

---------------------------------------------------------------------------------------------
-- Rainbow delimiters
---------------------------------------------------------------------------------------------

local OPEN = { ['('] = true, ['['] = true, ['{'] = true }
local BRACKETS = { '(', ')', '[', ']', '{', '}' }

--- @type table<string, vim.treesitter.Query|false>
local queries = {}

--- A query for the bracket tokens that exist in `lang`'s grammar, or false.
--- @param lang string
--- @return vim.treesitter.Query|false
local function bracket_query(lang)
  if queries[lang] == nil then
    queries[lang] = false
    local ok, info = pcall(vim.treesitter.language.inspect, lang)
    if ok then
      local present = {} ---@type table<string, true>
      -- symbols: { ['"("'] = false, ... }: anonymous tokens are quoted and not named.
      for name, named in pairs(info.symbols) do
        if named == false then
          present[name:gsub('^"(.*)"$', '%1')] = true
        end
      end
      local parts = {}
      for _, b in ipairs(BRACKETS) do
        if present[b] then
          parts[#parts + 1] = ('"%s"'):format(b)
        end
      end
      if #parts > 0 then
        local src = '[' .. table.concat(parts, ' ') .. '] @b'
        local qok, q = pcall(vim.treesitter.query.parse, lang, src)
        queries[lang] = qok and q or false
      end
    end
  end
  return queries[lang]
end

--- Whether `node` has a bracket token as a direct child (cached per redraw).
--- @param node TSNode
--- @param cache table<string, boolean>
local function owns_bracket(node, cache)
  local id = node:id()
  local v = cache[id]
  if v == nil then
    v = false
    for child in node:iter_children() do
      if not child:named() and OPEN[child:type()] then
        v = true
        break
      end
    end
    cache[id] = v
  end
  return v
end

--- Nesting level of a bracket token: the number of bracket-owning nodes enclosing the node
--- that owns it. Matching brackets share their owner, so they get the same level.
--- @param bracket TSNode
--- @param cache table<string, boolean>
local function level_of(bracket, cache)
  local owner = bracket:parent()
  local level = 0
  local p = owner and owner:parent()
  while p do
    if owns_bracket(p, cache) then
      level = level + 1
    end
    p = p:parent()
  end
  return level
end

local rainbow_bufs = {} ---@type table<integer, boolean>

--- @param buf integer
--- @param top integer
--- @param bot integer
local function rainbow_win(buf, top, bot)
  local parser = vim.treesitter.get_parser(buf, nil, { error = false })
  if not parser then
    return
  end
  local cache = {}
  parser:for_each_tree(function(tree, ltree)
    local q = bracket_query(ltree:lang())
    if not q then
      return
    end
    for _, node in q:iter_captures(tree:root(), buf, top, bot + 1) do
      local srow, scol, erow, ecol = node:range()
      if srow == erow and ecol > scol then
        local group = 'WgvimRainbow' .. (level_of(node, cache) % M.levels + 1)
        api.nvim_buf_set_extmark(buf, ns, srow, scol, {
          end_col = ecol,
          hl_group = group,
          ephemeral = true,
          priority = 125, -- above treesitter (100) and semantic tokens (125 is LSP's max)
        })
      end
    end
  end)
end

---------------------------------------------------------------------------------------------
-- Scope guide
---------------------------------------------------------------------------------------------

--- Display width of the indentation of line `lnum` (1-based), or nil for a blank line.
local function indent_of(buf, lnum)
  local line = api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
  if line == nil or line:match('^%s*$') then
    return nil
  end
  return vim.fn.indent(lnum)
end

--- The block around `lnum`: the lines whose indentation is at least that of `lnum` (or of the
--- next non-blank line), and the column of the line that opens it.
--- @return integer? first, integer? last, integer? col (0-based rows; display column)
local function scope_at(buf, lnum)
  local n = api.nvim_buf_line_count(buf)
  local l = lnum
  local ind = indent_of(buf, l)
  while ind == nil and l < n do
    l = l + 1
    ind = indent_of(buf, l)
  end
  if ind == nil or ind == 0 then
    return nil
  end
  local first, last = l, l
  while first > 1 do
    local i = indent_of(buf, first - 1)
    if i ~= nil and i < ind then
      break
    end
    first = first - 1
  end
  while last < n do
    local i = indent_of(buf, last + 1)
    if i ~= nil and i < ind then
      break
    end
    last = last + 1
  end
  -- Blank lines at either end separate blocks rather than belong to this one.
  while first < last and indent_of(buf, first) == nil do
    first = first + 1
  end
  while last > first and indent_of(buf, last) == nil do
    last = last - 1
  end
  -- The guide goes under the line that opens the block: the nearest non-blank line above.
  local header = 0
  for h = first - 1, 1, -1 do
    local i = indent_of(buf, h)
    if i ~= nil then
      header = i
      break
    end
  end
  return first - 1, last - 1, header
end

--- @class (private) wgvim.reading.Scope
--- @field buf integer
--- @field first integer
--- @field last integer
--- @field col integer
--- @field leftcol integer

local scope_win = {} ---@type table<integer, wgvim.reading.Scope>

local function update_scope(win)
  win = win or api.nvim_get_current_win()
  if not state.scope or not api.nvim_win_is_valid(win) then
    scope_win[win] = nil
    return
  end
  local buf = api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= '' then
    scope_win[win] = nil
    return
  end
  local lnum = api.nvim_win_get_cursor(win)[1]
  -- nvim_buf_call() returns only the first value, so pack them.
  local r = api.nvim_buf_call(buf, function()
    return { scope_at(buf, lnum) }
  end)
  local first, last, col = r[1], r[2], r[3]
  local old = scope_win[win]
  if first == nil then
    scope_win[win] = nil
  else
    scope_win[win] = { buf = buf, first = first, last = last, col = col, leftcol = 0 }
  end
  local new = scope_win[win]
  local changed = (old == nil) ~= (new == nil)
    or (old and new and (old.buf ~= new.buf or old.first ~= new.first or old.last ~= new.last
      or old.col ~= new.col))
  if changed then
    -- Lines that did not change are not redrawn on their own.
    api.nvim__redraw({ win = win, valid = false })
  end
end

local function scope_line(win, buf, row)
  local s = scope_win[win]
  if not s or s.buf ~= buf or row < s.first or row > s.last then
    return
  end
  local wincol = s.col - s.leftcol
  if wincol < 0 then
    return
  end
  -- Only where that column is indentation (or past the end of a short or blank line).
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
  local byte = vim.fn.virtcol2col(win, row + 1, s.col + 1)
  local ch = byte > 0 and line:sub(byte, byte) or ''
  if ch ~= '' and not ch:match('%s') then
    return
  end
  api.nvim_buf_set_extmark(buf, ns, row, 0, {
    virt_text = { { state.scope_char, 'WgvimScope' } },
    virt_text_win_col = wincol,
    hl_mode = 'combine',
    ephemeral = true,
    priority = 10,
  })
end

---------------------------------------------------------------------------------------------
-- References
---------------------------------------------------------------------------------------------

local ref_match = {} ---@type table<integer, integer> window -> matchadd() id

local function clear_references()
  for win, id in pairs(ref_match) do
    if api.nvim_win_is_valid(win) then
      pcall(vim.fn.matchdelete, id, win)
    end
    ref_match[win] = nil
  end
  if #vim.lsp.get_clients({ bufnr = 0, method = 'textDocument/documentHighlight' }) > 0 then
    vim.lsp.buf.clear_references()
  end
end

local function show_references()
  clear_references()
  if vim.bo.buftype ~= '' then
    return
  end
  if #vim.lsp.get_clients({ bufnr = 0, method = 'textDocument/documentHighlight' }) > 0 then
    vim.lsp.buf.document_highlight()
    return
  end
  local word = vim.fn.expand('<cword>')
  if word == '' or not word:match('^[%w_]+$') then
    return
  end
  local win = api.nvim_get_current_win()
  ref_match[win] = vim.fn.matchadd('WgvimReference', [[\V\<]] .. word .. [[\>]], 5)
end

---------------------------------------------------------------------------------------------
-- Decoration provider (rainbow and scope)
---------------------------------------------------------------------------------------------

-- A decoration provider that raises an error is disabled for the rest of the session, so
-- errors are caught and kept for :Reading to report.
local function guarded(f, ...)
  local ok, err = pcall(f, ...)
  if not ok then
    M.last_error = err
  end
  return ok
end

api.nvim_set_decoration_provider(ns, {
  on_win = function(_, win, buf, top, bot)
    if state.rainbow and rainbow_bufs[buf] ~= false and vim.treesitter.highlighter.active[buf] then
      guarded(rainbow_win, buf, top, bot)
    end
    local s = state.scope and scope_win[win]
    if s then
      local info = vim.fn.getwininfo(win)[1]
      s.leftcol = info and info.leftcol or 0
    end
    return s and true or false
  end,
  on_line = function(_, win, buf, row)
    guarded(scope_line, win, buf, row)
  end,
})

---------------------------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------------------------

local function refresh_autocmds()
  api.nvim_clear_autocmds({ group = augroup })
  api.nvim_create_autocmd('ColorScheme', { group = augroup, callback = set_default_highlights })
  if state.scope then
    local events = { 'CursorMoved', 'CursorMovedI', 'WinEnter', 'BufWinEnter' }
    vim.list_extend(events, { 'TextChanged', 'TextChangedI' })
    api.nvim_create_autocmd(events, {
      group = augroup,
      callback = function()
        update_scope()
      end,
    })
    update_scope()
  else
    scope_win = {}
  end
  if state.rainbow then
    -- An edit can change the nesting level of brackets on lines that were not edited.
    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
      group = augroup,
      callback = function(a)
        for _, win in ipairs(vim.fn.win_findbuf(a.buf)) do
          api.nvim__redraw({ win = win, valid = false })
        end
      end,
    })
  end
  if state.references then
    api.nvim_create_autocmd('CursorHold', { group = augroup, callback = show_references })
    api.nvim_create_autocmd({ 'CursorMoved', 'InsertEnter', 'BufLeave', 'WinLeave' }, {
      group = augroup,
      callback = clear_references,
    })
  else
    clear_references()
  end
end

--- Turns reading aids on or off.
--- @param opts? wgvim.reading.Opts
function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    if state[k] == nil then
      error(('wgvim.reading: unknown option "%s"'):format(k))
    end
    state[k] = v
  end
  set_default_highlights()
  refresh_autocmds()
  vim.cmd.redraw({ bang = true })
end

--- Turns rainbow delimiters off (or back on) for one buffer.
--- @param buf? integer
--- @param enable boolean
function M.rainbow_buf(buf, enable)
  rainbow_bufs[(buf == nil or buf == 0) and api.nvim_get_current_buf() or buf] = enable
  vim.cmd.redraw({ bang = true })
end

--- @return table<string, boolean>
function M.status()
  return { rainbow = state.rainbow, scope = state.scope, references = state.references }
end

-- For tests.
M._scope_at = scope_at

local features = { 'rainbow', 'scope', 'references' }

api.nvim_create_user_command('Reading', function(a)
  local feature, action = a.fargs[1], a.fargs[2] or 'toggle'
  if feature == nil then
    local s = M.status()
    local function f(b)
      return b and 'on' or 'off'
    end
    print(('rainbow: %s, scope: %s, references: %s%s'):format(
      f(s.rainbow),
      f(s.scope),
      f(s.references),
      M.last_error and ('\nlast error: ' .. M.last_error) or ''
    ))
    return
  end
  if not vim.tbl_contains(features, feature) then
    api.nvim_echo({ { 'Reading: unknown feature: ' .. feature, 'ErrorMsg' } }, true, {})
    return
  end
  local value = ({ on = true, off = false, toggle = not state[feature] })[action]
  if value == nil then
    api.nvim_echo({ { 'Reading: expected on, off or toggle', 'ErrorMsg' } }, true, {})
    return
  end
  M.setup({ [feature] = value })
end, {
  nargs = '*',
  desc = 'Turn wgvim reading aids on or off (:help wgvim-reading)',
  complete = function(_, line)
    local n = #vim.split(line, '%s+', { trimempty = false })
    return n <= 2 and features or { 'on', 'off', 'toggle' }
  end,
})

set_default_highlights()

return M
