-- wgvim: reading aids (|wgvim-reading|).
--
-- - rainbow: colour each nesting level of (), [] and {} differently, from the treesitter tree
--   (brackets in strings and comments are not part of the tree's bracket nodes, so they are
--   left alone);
-- - scope: draw a thin vertical line along the block the cursor is in;
-- - references: highlight other uses of the name under the cursor (LSP documentHighlight when
--   a language server provides it, otherwise the word under the cursor in the window);
-- - context: show the first lines of the blocks (function, loop, ...) that have scrolled off
--   the top of the window, in a float over the window's first lines.
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
--- @field context? boolean
--- @field scope_char? string Character drawn by the scope guide (default "│").
--- @field context_max? integer Most lines the context shows (default 3).

local state = {
  rainbow = false,
  scope = false,
  references = false,
  context = false,
  scope_char = '│',
  context_max = 3,
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
  api.nvim_set_hl(0, 'WgvimContext', { link = 'NormalFloat', default = true })
  api.nvim_set_hl(0, 'WgvimContextLineNr', { link = 'LineNr', default = true })
  api.nvim_set_hl(0, 'WgvimContextBottom', { underline = true, default = true })
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

--- Calls `emit(row, start_col, end_col, group)` for each bracket in rows `top`..`bot`.
--- @param buf integer
--- @param top integer
--- @param bot integer
--- @param emit fun(row: integer, scol: integer, ecol: integer, group: string)
local function rainbow_marks(buf, top, bot, emit)
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
        emit(srow, scol, ecol, 'WgvimRainbow' .. (level_of(node, cache) % M.levels + 1))
      end
    end
  end)
end

-- Above treesitter (100) and semantic tokens (125 is LSP's max).
local RAINBOW_PRIORITY = 125

local function rainbow_win(buf, top, bot)
  rainbow_marks(buf, top, bot, function(row, scol, ecol, group)
    api.nvim_buf_set_extmark(buf, ns, row, scol, {
      end_col = ecol,
      hl_group = group,
      ephemeral = true,
      priority = RAINBOW_PRIORITY,
    })
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
-- Context
---------------------------------------------------------------------------------------------

local ctx_ns = api.nvim_create_namespace('wgvim.reading.context')

--- @class (private) wgvim.reading.Context
--- @field buf integer scratch buffer shown in the float
--- @field win? integer the float, while shown
--- @field rows integer[] rows of the source buffer it shows
--- @field key? string what was last rendered

local context_of = {} ---@type table<integer, wgvim.reading.Context> source window -> context

local function line_at(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
end

-- A line with nothing but brackets (a "{" on a line of its own) does not say what the block is.
local function says_nothing(line)
  return line:match('^[%s%(%)%[%]{}]*$') ~= nil
end

--- Rows (0-based, outermost first) of the first lines of the syntax nodes around `row` that
--- start above it.
--- @return integer[]?
local function context_rows_ts(buf, row)
  local parser = vim.treesitter.get_parser(buf, nil, { error = false })
  if not parser then
    return nil
  end
  local col = #line_at(buf, row):match('^%s*')
  local node = parser:named_node_for_range({ row, col, row, col }, { ignore_injections = true })
  local rows, seen = {}, {}
  while node and node:parent() do -- not the root: that is the whole file
    local srow = node:start()
    if srow < row and not seen[srow] then
      seen[srow] = true
      if not says_nothing(line_at(buf, srow)) then
        table.insert(rows, 1, srow)
      end
    end
    node = node:parent()
  end
  return rows
end

--- Like context_rows_ts(), from indentation: each line above `row` indented less than the
--- block below it. Must run in `buf` (indent()).
local function context_rows_indent(buf, row)
  local n = api.nvim_buf_line_count(buf)
  local l = row + 1
  local ind = indent_of(buf, l)
  while ind == nil and l < n do
    l = l + 1
    ind = indent_of(buf, l)
  end
  local rows = {}
  for h = row, 1, -1 do
    if ind == nil or ind == 0 then
      break
    end
    local i = indent_of(buf, h)
    if i ~= nil and i < ind and not says_nothing(line_at(buf, h - 1)) then
      table.insert(rows, 1, h - 1)
      ind = i
    end
  end
  return rows
end

--- @return integer[]
local function context_rows(buf, row)
  if vim.treesitter.highlighter.active[buf] then
    local rows = context_rows_ts(buf, row)
    if rows then
      return rows
    end
  end
  return context_rows_indent(buf, row)
end

--- At most `max` rows: the outermost one (usually the function) and the innermost others.
local function trim(rows, max)
  if #rows <= max then
    return rows
  end
  local r = { rows[1] }
  for i = #rows - max + 2, #rows do
    r[#r + 1] = rows[i]
  end
  return max >= 1 and r or {}
end

--- The rows to show in `win`, and whether the cursor is on a line the float would cover.
--- Must run in `win` (line('w0'), folds).
--- @return integer[] rows, boolean covers_cursor
local function compute_context(win, buf)
  local top = vim.fn.line('w0')
  local last = api.nvim_buf_line_count(buf)
  -- The buffer lines on the window's first screen lines (closed folds take one screen line).
  local shown = { top }
  local function shown_at(i)
    while #shown <= i do
      local l = shown[#shown]
      local e = vim.fn.foldclosedend(l)
      shown[#shown + 1] = (e ~= -1 and e or l) + 1
    end
    return shown[i + 1]
  end
  -- The float covers as many lines as it has, which changes which line it is the context of.
  local rows = {}
  local covered = 0
  for _ = 1, 3 do
    local lnum = shown_at(covered)
    if lnum > last then
      break
    end
    rows = trim(context_rows(buf, lnum - 1), state.context_max)
    if #rows == covered then
      break
    end
    covered = #rows
  end
  local cursor = api.nvim_win_get_cursor(win)[1]
  return rows, #rows > 0 and cursor < shown_at(#rows)
end

local function hide_context(win)
  local c = context_of[win]
  if c and c.win and api.nvim_win_is_valid(c.win) then
    api.nvim_win_close(c.win, true)
  end
  if c then
    c.win, c.key = nil, nil
  end
end

local function drop_context(win)
  hide_context(win)
  local c = context_of[win]
  if c and api.nvim_buf_is_valid(c.buf) then
    api.nvim_buf_delete(c.buf, { force = true })
  end
  context_of[win] = nil
end

--- Copies treesitter and rainbow highlighting of `rows` in `src` to the lines of `dst`.
local function copy_highlights(src, rows, dst, lines)
  local parser = vim.treesitter.highlighter.active[src]
    and vim.treesitter.get_parser(src, nil, { error = false })
  if not parser then
    return
  end
  local function mark(i, scol, ecol, group, priority)
    ecol = math.min(ecol, #lines[i])
    if ecol > scol then
      api.nvim_buf_set_extmark(dst, ctx_ns, i - 1, scol, {
        end_col = ecol,
        hl_group = group,
        priority = priority,
      })
    end
  end
  parser:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    local q = vim.treesitter.query.get(lang, 'highlights')
    if not q then
      return
    end
    for i, row in ipairs(rows) do
      for id, node, md in q:iter_captures(tree:root(), src, row, row + 1) do
        local name = q.captures[id]
        if name:sub(1, 1) ~= '_' and name ~= 'spell' and name ~= 'nospell' then
          local range = vim.treesitter.get_range(node, src, md[id]) -- { sr, sc, sb, er, ec, eb }
          local sr, sc, er, ec = range[1], range[2], range[4], range[5]
          if sr <= row and er >= row then
            local prio = tonumber(md.priority or (md[id] and md[id].priority)) or 100
            local scol = sr < row and 0 or sc
            local ecol = er > row and #lines[i] or ec
            mark(i, scol, ecol, '@' .. name .. '.' .. lang, prio)
          end
        end
      end
    end
  end)
  if state.rainbow and rainbow_bufs[src] ~= false then
    for i, row in ipairs(rows) do
      rainbow_marks(src, row, row, function(r, scol, ecol, group)
        if r == row then
          mark(i, scol, ecol, group, RAINBOW_PRIORITY)
        end
      end)
    end
  end
end

local function update_context(win)
  if not state.context or not api.nvim_win_is_valid(win) then
    hide_context(win)
    return
  end
  if api.nvim_win_get_config(win).relative ~= '' then
    return -- floats (our own among them)
  end
  local buf = api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= '' or vim.wo[win].diff then
    hide_context(win)
    return
  end
  local r = api.nvim_win_call(win, function()
    return { compute_context(win, buf) }
  end)
  local rows, covers_cursor = r[1], r[2]
  if #rows == 0 or covers_cursor then
    hide_context(win)
    return
  end

  local info = vim.fn.getwininfo(win)[1]
  local c = context_of[win]
  if not c or not api.nvim_buf_is_valid(c.buf) then
    c = { buf = api.nvim_create_buf(false, true), rows = {} }
    context_of[win] = c
  end
  local number = vim.wo[win].number or vim.wo[win].relativenumber
  local key = table.concat({
    buf,
    api.nvim_buf_get_changedtick(buf),
    info.width,
    info.textoff,
    tostring(number),
    tostring(state.rainbow),
    table.concat(rows, ','),
  }, ':')
  if c.key ~= key then
    local lines = {}
    for i, row in ipairs(rows) do
      lines[i] = line_at(buf, row):gsub('%s+$', '')
    end
    api.nvim_buf_set_lines(c.buf, 0, -1, false, lines)
    vim.bo[c.buf].tabstop = vim.bo[buf].tabstop
    api.nvim_buf_clear_namespace(c.buf, ctx_ns, 0, -1)
    if vim.treesitter.highlighter.active[buf] then
      vim.bo[c.buf].syntax = ''
      copy_highlights(buf, rows, c.buf, lines)
    elseif vim.bo[c.buf].syntax ~= vim.bo[buf].syntax then
      vim.bo[c.buf].syntax = vim.bo[buf].syntax
    end
    for i, row in ipairs(rows) do
      -- The gutter: line numbers where the window shows them, so the lines are not mistaken
      -- for the ones they cover.
      if info.textoff > 0 then
        local text = number and ('%' .. (info.textoff - 1) .. 'd '):format(row + 1)
          or (' '):rep(info.textoff)
        api.nvim_buf_set_extmark(c.buf, ctx_ns, i - 1, 0, {
          virt_text = { { text, 'WgvimContextLineNr' } },
          virt_text_pos = 'inline',
        })
      end
    end
    api.nvim_buf_set_extmark(c.buf, ctx_ns, #rows - 1, 0, { line_hl_group = 'WgvimContextBottom' })
    c.rows, c.key = rows, key
  end
  local config = {
    relative = 'win',
    win = win,
    row = 0,
    col = 0,
    width = info.width,
    height = #rows,
    focusable = false,
    style = 'minimal',
    zindex = 20,
  }
  if c.win and api.nvim_win_is_valid(c.win) then
    api.nvim_win_set_config(c.win, config)
  else
    config.noautocmd = true
    c.win = api.nvim_open_win(c.buf, false, config)
    vim.wo[c.win].winhighlight = 'NormalFloat:WgvimContext'
    vim.wo[c.win].wrap = false
  end
end

--- Jumps to the innermost line shown by the context of the current window.
function M.context_jump()
  local c = context_of[api.nvim_get_current_win()]
  local rows = c and c.win and c.rows or {}
  if #rows > 0 then
    vim.cmd("normal! m'")
    api.nvim_win_set_cursor(0, { rows[#rows] + 1, 0 })
    vim.cmd('normal! ^')
  end
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
  if state.context then
    api.nvim_create_autocmd({
      'CursorMoved',
      'CursorMovedI',
      'BufWinEnter',
      'TextChanged',
      'TextChangedI',
      'WinResized',
    }, {
      group = augroup,
      callback = function()
        guarded(update_context, api.nvim_get_current_win())
      end,
    })
    api.nvim_create_autocmd('WinScrolled', {
      group = augroup,
      callback = function()
        for id in pairs(vim.v.event) do
          local win = tonumber(id)
          if win then
            guarded(update_context, win)
          end
        end
      end,
    })
    api.nvim_create_autocmd('WinClosed', {
      group = augroup,
      callback = function(a)
        drop_context(tonumber(a.match))
      end,
    })
    for _, win in ipairs(api.nvim_list_wins()) do
      guarded(update_context, win)
    end
  else
    for win in pairs(context_of) do
      drop_context(win)
    end
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
  return {
    rainbow = state.rainbow,
    scope = state.scope,
    references = state.references,
    context = state.context,
  }
end

-- For tests.
M._scope_at = scope_at

local features = { 'rainbow', 'scope', 'references', 'context' }

api.nvim_create_user_command('Reading', function(a)
  local feature, action = a.fargs[1], a.fargs[2] or 'toggle'
  if feature == nil then
    local s = M.status()
    local function f(b)
      return b and 'on' or 'off'
    end
    print(('rainbow: %s, scope: %s, references: %s, context: %s%s'):format(
      f(s.rainbow),
      f(s.scope),
      f(s.references),
      f(s.context),
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
