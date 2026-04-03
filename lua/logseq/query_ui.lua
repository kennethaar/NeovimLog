--- logseq.nvim query UI
--- Renders Logseq simple query results inline, directly below each {{query}} block.
--- Uses Neovim extmarks to track section positions across edits.
---
--- Layout (per query block):
---   ──────────────────────────────────────────────────────────────
---    [~]  [LIST]  [table]    N results
---   ──────────────────────────────────────────────────────────────
---    • Block content                       page-name · date
---   ──────────────────────────────────────────────────────────────
---
--- Table mode adds column headers, optional column picker, and │-separated cells.
---
--- Keymaps (active only inside a query section):
---   <CR>  activate button / navigate to source block
---   r     refresh this query
---   t     toggle list ↔ table mode
---   c     toggle column picker (table mode only)

local config      = require("logseq.config")
local qparser     = require("logseq.query_parser")
local engine      = require("logseq.query_engine")
local indexer     = require("logseq.indexer")

local M = {}

local NS = vim.api.nvim_create_namespace("logseq_query")

-- ── Constants ──────────────────────────────────────────────────────────

local SEP = string.rep("─", 62)

local COLUMN_ORDER  = { "block", "page", "date", "todo", "tags" }
local COLUMN_LABELS = { block = "Block", page = "Page", date = "Date", todo = "TODO", tags = "Tags" }
local COLUMN_WIDTHS = { block = 34, page = 15, date = 12, todo = 9, tags = 16 }

local DEFAULT_COLUMNS = { block = true, page = true, date = true, todo = false, tags = false }

--- Extract the leaf segment of a (possibly namespaced) page name.
--- "1/Project" → "Project", "Foo Bar" → "Foo Bar"
local function leaf_name(name)
  return name:match("[^/]+$") or name
end

-- ── State ──────────────────────────────────────────────────────────────

M._state = {}   -- bufnr → { queries = [...] }

local function get_state(bufnr)
  if not M._state[bufnr] then M._state[bufnr] = { queries = {} } end
  return M._state[bufnr]
end

-- ── Buffer helpers ─────────────────────────────────────────────────────

local function with_modifiable(bufnr, fn)
  local was_mod = vim.bo[bufnr].modified
  local was_ma  = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  fn()
  vim.bo[bufnr].modified   = was_mod
  vim.bo[bufnr].modifiable = was_ma
end

-- ── Extmark helpers ────────────────────────────────────────────────────

--- Return the 0-indexed row of a query's {{query}} line via its extmark.
local function query_row_0(bufnr, q)
  if not q.query_mark then return nil end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, q.query_mark, {})
  return (pos and #pos > 0) and pos[1] or nil
end

--- Return the 0-indexed row of the first line of a query's rendered section.
local function section_row_0(bufnr, q)
  if not q.section_mark then return nil end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, q.section_mark, {})
  return (pos and #pos > 0) and pos[1] or nil
end

-- ── Section management ─────────────────────────────────────────────────

local function remove_section(bufnr, q)
  if not q.section_mark then return end
  pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, q.section_mark)
  q.section_mark       = nil
  q.section_line_count = nil
end

local function remove_all_sections(bufnr)
  local state = get_state(bufnr)
  -- Collect sections with their current absolute start rows.
  local with_rows = {}
  for _, q in ipairs(state.queries) do
    local s0 = q.section_mark and section_row_0(bufnr, q)
    if s0 then with_rows[#with_rows + 1] = { q = q, s0 = s0 } end
  end
  -- Remove bottom-to-top so earlier sections aren't shifted by later removals.
  table.sort(with_rows, function(a, b) return a.s0 > b.s0 end)
  for _, entry in ipairs(with_rows) do remove_section(bufnr, entry.q) end
end

-- ── Display builder ────────────────────────────────────────────────────

local function truncate(s, max)
  if not s or #s == 0 then return "" end
  if #s <= max then return s end
  return s:sub(1, max - 1) .. "…"
end

local function pad(s, width)
  if not s then s = "" end
  if #s >= width then return s:sub(1, width) end
  return s .. string.rep(" ", width - #s)
end

--- Build the header line and return it plus a button list.
--- Each button: { from, to, action, data }  (1-based byte columns)
local function make_header(q)
  -- Incremental string builder that tracks exact byte positions.
  local buf = {}
  local pos = 0
  local buttons = {}

  local function push(s, action, data)
    local from = pos + 1
    buf[#buf + 1] = s
    pos = pos + #s
    if action then
      buttons[#buttons + 1] = { from = from, to = pos, action = action, data = data }
    end
  end

  push(" ")
  push("[~]",   "refresh")
  push("  ")
  push(q.mode == "list"  and "[LIST]"  or "[list]",  "set_mode", "list")
  push("  ")
  push(q.mode == "table" and "[TABLE]" or "[table]", "set_mode", "table")

  if q.mode == "table" then
    push("  ")
    push(q.show_columns and "[COLS ^]" or "[cols v]", "toggle_col_picker")
  end

  local n = q.results and #q.results or 0
  push(string.format("    %d %s", n, n == 1 and "result" or "results"))

  return table.concat(buf), buttons
end

--- Build the inline column-picker lines.
--- Returns lines[], smap{ rel_idx → action }
local function make_column_picker(q)
  local lines = { " ╭──────────────────╮" }
  local smap  = {}
  for _, key in ipairs(COLUMN_ORDER) do
    local mark = q.columns[key] and "[x]" or "[ ]"
    lines[#lines + 1] = string.format(" │ %s %-14s│", mark, COLUMN_LABELS[key])
    smap[#lines] = { action = "toggle_column", column = key }
  end
  lines[#lines + 1] = " ╰──────────────────╯"
  return lines, smap
end

--- Build the full section display.
--- Returns: lines[], source_map{ rel → action }, header_rel (1-based), header_buttons[]
local function build_display(q)
  local lines  = {}
  local smap   = {}
  local header_rel
  local header_buttons

  local function add(line, action)
    lines[#lines + 1] = line
    if action then smap[#lines] = action end
    return #lines
  end

  -- Top separator
  add(SEP)

  -- Header
  local hdr, hbtns = make_header(q)
  header_rel     = add(hdr)
  header_buttons = hbtns

  -- Column picker (table mode, when open)
  if q.mode == "table" and q.show_columns then
    local picker_lines, picker_smap = make_column_picker(q)
    local base = #lines
    for _, pl in ipairs(picker_lines) do add(pl) end
    for rel, action in pairs(picker_smap) do smap[base + rel] = action end
  end

  -- Separator before results
  add(SEP)

  -- Table column headers
  if q.mode == "table" then
    local cells, seps = {}, {}
    for _, key in ipairs(COLUMN_ORDER) do
      if q.columns[key] then
        cells[#cells + 1] = pad(COLUMN_LABELS[key], COLUMN_WIDTHS[key])
        seps[#seps   + 1] = string.rep("─", COLUMN_WIDTHS[key])
      end
    end
    add(" " .. table.concat(cells, " │ "))
    add(" " .. table.concat(seps,  "─┼─"))
  end

  -- Results
  local results = q.results or {}


  local function list_line(r)
    if r.is_page then
      -- For page-level results, just show the page name (optionally with date for journals)
      local suffix = r.date and (" · " .. r.date) or ""
      local content = truncate(r.source_page, 46)
      local padding = math.max(1, 58 - #content - #suffix)
      return " • " .. content .. string.rep(" ", padding) .. suffix
    else
      local suffix   = r.source_page .. (r.date and (" · " .. r.date) or "")
      local content  = truncate(r.content, 46)
      local padding  = math.max(1, 58 - #content - #suffix)
      return " • " .. content .. string.rep(" ", padding) .. suffix
    end
  end

  local function table_line(r)
    local vals = {
      block = truncate(r.content,    COLUMN_WIDTHS.block),
      page  = truncate(r.source_page, COLUMN_WIDTHS.page),
      date  = truncate(r.date or "", COLUMN_WIDTHS.date),
      todo  = truncate(r.todo_state or "", COLUMN_WIDTHS.todo),
      tags  = truncate(table.concat(r.tags or {}, " "), COLUMN_WIDTHS.tags),
    }
    local cells = {}
    for _, key in ipairs(COLUMN_ORDER) do
      if q.columns[key] then cells[#cells + 1] = pad(vals[key], COLUMN_WIDTHS[key]) end
    end
    return " " .. table.concat(cells, " │ ")
  end

  local line_fn = q.mode == "table" and table_line or list_line

  for _, r in ipairs(results) do
    add(line_fn(r), { action = "navigate", file = r.source_file, line = r.line_start })
  end

  if #results == 0 then
    add("  (no results)")
  end

  -- Bottom separator
  add(SEP)

  return lines, smap, header_rel, header_buttons
end

-- ── Rendering ──────────────────────────────────────────────────────────

local function apply_highlights(bufnr, abs0, lines, header_rel, header_buttons, q)
  -- Separator lines → Comment
  for i, line in ipairs(lines) do
    if line == SEP then
      vim.api.nvim_buf_add_highlight(bufnr, NS, "Comment", abs0 + i - 1, 0, -1)
    end
  end

  -- Header line
  local hdr_abs = abs0 + header_rel - 1
  vim.api.nvim_buf_add_highlight(bufnr, NS, "Normal", hdr_abs, 0, -1)
  for _, btn in ipairs(header_buttons or {}) do
    local hl = (btn.action == "set_mode" and btn.data == q.mode) and "Bold"
            or (btn.action == "refresh")                          and "Special"
            or "Comment"
    -- col args are 0-based byte offsets: from-1 and to (exclusive end)
    vim.api.nvim_buf_add_highlight(bufnr, NS, hl, hdr_abs, btn.from - 1, btn.to)
  end

  -- Column picker checkmarks
  if q.mode == "table" and q.show_columns then
    -- Lines after the header until the next SEP are picker lines.
    for i = header_rel + 1, #lines do
      if lines[i] == SEP then break end
      vim.api.nvim_buf_add_highlight(bufnr, NS, "Comment", abs0 + i - 1, 0, -1)
      -- Highlight [x] in green, [ ] in Normal
      local line = lines[i]
      local mark_s, mark_e = line:find("%[.%]", 1, false)
      if mark_s then
        local hl = line:sub(mark_s + 1, mark_s + 1) == "x" and "DiagnosticOk" or "Comment"
        vim.api.nvim_buf_add_highlight(bufnr, NS, hl, abs0 + i - 1, mark_s - 1, mark_e)
      end
    end
  end

  -- Table column-header line (the line right after the post-picker SEP)
  if q.mode == "table" then
    for i, line in ipairs(lines) do
      -- The second SEP is the results separator; the line after it is the column header.
      if line == SEP and i > header_rel then
        local col_hdr_abs = abs0 + i  -- line after SEP (0-indexed = abs0+i)
        if col_hdr_abs < abs0 + #lines then
          vim.api.nvim_buf_add_highlight(bufnr, NS, "Bold", col_hdr_abs, 0, -1)
        end
        break
      end
    end
  end
end

local function virt_lines_from_lines(lines)
  local virt_lines = {}
  for i, line in ipairs(lines) do
    local hl = (line == SEP) and "Comment" or "Normal"
    virt_lines[#virt_lines + 1] = { { line, hl } }
  end
  return virt_lines
end

local function render_one(bufnr, q)
  local qrow = query_row_0(bufnr, q)
  if not qrow then return end
  if q.hidden then return end

  local lines = build_display(q)
  local virt_lines = virt_lines_from_lines(lines)

  if q.section_mark then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, q.section_mark)
  end

  q.section_mark       = vim.api.nvim_buf_set_extmark(bufnr, NS, qrow, 0, {
    virt_lines      = virt_lines,
    virt_lines_above = false,
  })
  q.section_line_count = #lines
end

-- ── Query scanning ─────────────────────────────────────────────────────

local function scan_queries(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local found = {}
  for i, line in ipairs(lines) do
    local qs = qparser.extract(line)
    if qs then found[#found + 1] = { row_0 = i - 1, query_str = qs } end
  end
  return found
end

-- ── Public render API ──────────────────────────────────────────────────

local function refresh_query(bufnr, q)
  remove_section(bufnr, q)
  if not q.ast then
    q.results = {}
    render_one(bufnr, q)
    return
  end
  local current_page = indexer.page_name_from_file(vim.api.nvim_buf_get_name(bufnr))
  engine.run(q.ast, function(results)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    q.results = results
    render_one(bufnr, q)
  end, current_page)
end

--- Re-render all queries in the buffer (called on BufReadPost and after save).
function M.render_all(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local state = get_state(bufnr)
  remove_all_sections(bufnr)

  -- Release old query marks.
  for _, q in ipairs(state.queries) do
    if q.query_mark then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, q.query_mark)
    end
  end
  state.queries = {}

  local found = scan_queries(bufnr)
  local current_page = indexer.page_name_from_file(vim.api.nvim_buf_get_name(bufnr))
  for _, f in ipairs(found) do
    local ast, err = qparser.parse(f.query_str)
    local q = {
      query_mark         = vim.api.nvim_buf_set_extmark(bufnr, NS, f.row_0, 0, {}),
      query_str          = f.query_str,
      ast                = ast,
      parse_error        = err,
      section_mark       = nil,
      section_line_count = nil,
      mode               = "list",
      columns            = vim.deepcopy(DEFAULT_COLUMNS),
      show_columns       = false,
      hidden             = false,
      results            = nil,
      source_map         = nil,
      header_rel         = nil,
      header_buttons     = nil,
    }
    state.queries[#state.queries + 1] = q

    if ast then
      engine.run(ast, function(results)
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        q.results = results
        render_one(bufnr, q)
      end, current_page)
    else
      q.results = {}
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then render_one(bufnr, q) end
      end)
    end
  end
end

-- ── Navigation & interaction ───────────────────────────────────────────

--- True if lnum (1-indexed) is on a query line.
function M.in_any_region(bufnr, lnum)
  local state = get_state(bufnr)
  for _, q in ipairs(state.queries) do
    local qrow = query_row_0(bufnr, q)
    if qrow and lnum == qrow + 1 then return true end
  end
  return false
end

local function handle_button(bufnr, q, action, data)
  if action == "refresh" then
    refresh_query(bufnr, q)

  elseif action == "set_mode" then
    remove_section(bufnr, q)
    q.mode         = data
    q.show_columns = false
    render_one(bufnr, q)

  elseif action == "toggle_col_picker" then
    remove_section(bufnr, q)
    q.show_columns = not q.show_columns
    render_one(bufnr, q)
  end
end

local function dispatch_smap(bufnr, q, action)
  if action.action == "navigate" then
    vim.cmd("normal! m'")
    vim.cmd("edit " .. vim.fn.fnameescape(action.file))
    pcall(vim.api.nvim_win_set_cursor, 0, { action.line, 0 })

  elseif action.action == "toggle_column" then
    remove_section(bufnr, q)
    q.columns[action.column] = not q.columns[action.column]
    render_one(bufnr, q)
  end
end

--- Handle <CR> inside a query section. Returns true if the press was consumed.
function M.navigate(bufnr)
  bufnr      = bufnr or vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum = cursor[1]        -- 1-indexed
  local col  = cursor[2] + 1   -- 1-indexed byte

  local state = get_state(bufnr)
  for _, q in ipairs(state.queries) do
    local s0 = q.section_mark and section_row_0(bufnr, q)
    if s0 then
      local sec_start_1 = s0 + 1
      local sec_end_1   = s0 + (q.section_line_count or 0)

      if lnum >= sec_start_1 and lnum <= sec_end_1 then
        local rel = lnum - sec_start_1 + 1  -- 1-indexed within section

        -- Header line: dispatch column-based buttons.
        if rel == q.header_rel then
          for _, btn in ipairs(q.header_buttons or {}) do
            if col >= btn.from and col <= btn.to then
              handle_button(bufnr, q, btn.action, btn.data)
              return true
            end
          end
          return true
        end

        -- Source map entry (navigation, column toggle, etc.)
        local sa = q.source_map and q.source_map[rel]
        if sa then dispatch_smap(bufnr, q, sa) end
        return true
      end
    end
  end
  return false
end

--- Refresh the query on the current query line.
local function refresh_at(bufnr, lnum)
  local state = get_state(bufnr)
  for _, q in ipairs(state.queries) do
    local qrow = query_row_0(bufnr, q)
    if qrow and lnum == qrow + 1 then
      refresh_query(bufnr, q)
      return
    end
  end
end

--- Toggle list/table mode for the current query line.
local function toggle_mode_at(bufnr, lnum)
  local state = get_state(bufnr)
  for _, q in ipairs(state.queries) do
    local qrow = query_row_0(bufnr, q)
    if qrow and lnum == qrow + 1 then
      remove_section(bufnr, q)
      q.mode         = q.mode == "list" and "table" or "list"
      q.show_columns = false
      render_one(bufnr, q)
      return
    end
  end
end

--- Toggle the column picker for the current query line (table mode only).
local function toggle_cols_at(bufnr, lnum)
  local state = get_state(bufnr)
  for _, q in ipairs(state.queries) do
    local qrow = query_row_0(bufnr, q)
    if qrow and lnum == qrow + 1 then
      if q.mode ~= "table" then return end
      remove_section(bufnr, q)
      q.show_columns = not q.show_columns
      render_one(bufnr, q)
      return
    end
  end
end
--- Toggle rendering for the query under the cursor.
function M.toggle_render_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local state = get_state(bufnr)
  for _, q in ipairs(state.queries) do
    local qrow = query_row_0(bufnr, q)
    if qrow and lnum == qrow + 1 then
      q.hidden = not q.hidden
      if q.hidden then
        remove_section(bufnr, q)
      else
        render_one(bufnr, q)
      end
      return
    end
  end
end
-- ── Buffer lifecycle ───────────────────────────────────────────────────

local function on_write_pre(bufnr)
  local state = get_state(bufnr)
  state._had_queries = #state.queries > 0
  remove_all_sections(bufnr)
  for _, q in ipairs(state.queries) do
    if q.query_mark then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, q.query_mark)
      q.query_mark = nil
    end
  end
  state.queries = {}
end

local function on_write_post(bufnr)
  local state = get_state(bufnr)
  if not state._had_queries then return end
  state._had_queries = false
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then M.render_all(bufnr) end
  end)
end

local function guard_readonly(bufnr)
  if M.in_any_region(bufnr, vim.api.nvim_win_get_cursor(0)[1]) then
    vim.cmd("stopinsert")
    vim.notify("[logseq.nvim] Query results are read-only.", vim.log.levels.INFO)
  end
end

-- ── Setup ──────────────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local km      = config.current.keymaps or {}
  local bld_key = km.query_builder or "<leader>Q"

  _G.logseq_toggle_query_render = function()
    require("logseq.query_ui").toggle_render_at_cursor()
  end

  -- Query builder: open empty or pre-filled when on a {{query}} line.
  vim.keymap.set("n", bld_key, function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
    local qs   = qparser.extract(line)
    local ast  = qs and qparser.parse(qs)

    require("logseq.query_builder").open({
      existing_ast = type(ast) == "table" and ast or nil,
      replace_line = qs and lnum or nil,
      on_insert    = function(query_str, replace_lnum)
        local new_line = "- {{query " .. query_str .. "}}"
        if replace_lnum then
          with_modifiable(bufnr, function()
            vim.api.nvim_buf_set_lines(bufnr, replace_lnum - 1, replace_lnum, false, { new_line })
          end)
        else
          local cur = vim.api.nvim_win_get_cursor(0)[1]
          with_modifiable(bufnr, function()
            vim.api.nvim_buf_set_lines(bufnr, cur, cur, false, { new_line })
          end)
        end
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(bufnr) then M.render_all(bufnr) end
        end)
      end,
    })
  end, { buffer = bufnr, silent = true, desc = "Logseq: open query builder" })

  -- r  — refresh query (only active inside a query section; pass-through otherwise).
  vim.keymap.set("n", "r", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    if M.in_any_region(bufnr, lnum) then
      refresh_at(bufnr, lnum)
    else
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("r", true, false, true), "n", false)
    end
  end, { buffer = bufnr, silent = true })

  -- t  — toggle list/table (only inside a section).
  vim.keymap.set("n", "t", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    if M.in_any_region(bufnr, lnum) then
      toggle_mode_at(bufnr, lnum)
    else
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("t", true, false, true), "n", false)
    end
  end, { buffer = bufnr, silent = true })

  -- c  — toggle column picker (only inside a section, table mode).
  vim.keymap.set("n", "c", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    if M.in_any_region(bufnr, lnum) then
      toggle_cols_at(bufnr, lnum)
    else
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("c", true, false, true), "n", false)
    end
  end, { buffer = bufnr, silent = true })

  local group = vim.api.nvim_create_augroup("LogseqQuery_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufWritePre",  {
    group = group, buffer = bufnr,
    callback = function(ev) on_write_pre(ev.buf) end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group, buffer = bufnr,
    callback = function(ev) on_write_post(ev.buf) end,
  })
  vim.api.nvim_create_autocmd("InsertEnter",  {
    group = group, buffer = bufnr,
    callback = function(ev) guard_readonly(ev.buf) end,
  })
  vim.api.nvim_create_autocmd("BufUnload",    {
    group = group, buffer = bufnr,
    callback = function(ev) M._state[ev.buf] = nil end,
  })

  -- Initial render (scheduled so the buffer is fully loaded first).
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then M.render_all(bufnr) end
  end)
end

return M
