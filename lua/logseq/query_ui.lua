--- logseq.nvim query UI
--- Renders Logseq simple query results inline, directly below each {{query}} block.
--- Uses Neovim extmarks to track section positions across edits.
---
--- Layout (per query block):
---   ──────────────────────────────────────────────────────────────────────
---    [~]  [LIST]  [table]    N results
---   ──────────────────────────────────────────────────────────────────────
---    • Block content                       page-name · date
---   ──────────────────────────────────────────────────────────────────────
---
--- Table mode adds column headers, optional column picker, and │-separated cells.
---
--- Keymaps (active only inside a query section):
---   <CR>  activate button / navigate to source block
---   r     refresh this query
---   t     toggle list ↔ table mode
---   c     toggle column picker (table mode only)
---   r     refresh this query
---   t     toggle list ↔ table mode
---   c     toggle column picker (table mode only)

local config      = require("logseq.config")
local qparser     = require("logseq.query_parser")
local engine      = require("logseq.query_engine")
local indexer     = require("logseq.indexer")
local util        = require("logseq.util")

local M = {}

local NS = vim.api.nvim_create_namespace("logseq_query")

-- ── Constants ──────────────────────────────────────────────────────────

local SEP = string.rep("─", 70)

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
  if not M._state[bufnr] then
    M._state[bufnr] = {
      queries = {},  -- array of query objects
      regions = {},  -- query_idx → { start_line, end_line }
    }
  end
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

-- forward declaration for functions that are referenced before definition
local render_one
local remove_section

-- Small helpers to reduce duplicated code and nested conditionals
local function open_file_at(file, line)
  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  if line and line > 0 then pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 }) end
end

local function update_and_render(bufnr, q, updater)
  remove_section(bufnr, q)
  updater()
  render_one(bufnr, q)
end

local function execute_query(bufnr, q)
  if not q.ast then return end
  -- Prevent duplicate concurrent executions for the same query object.
  if q._running then return end
  q._running = true
  local current_page = indexer.page_name_from_file(vim.api.nvim_buf_get_name(bufnr))
  engine.run(q.ast, function(results)
    if not vim.api.nvim_buf_is_valid(bufnr) then q._running = false; return end
    q.results = results
    q.loading = false
    q.progress_current = nil
    q.progress_total = nil
    q._running = false
    render_one(bufnr, q)
  end, current_page,
  function(current, total)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    q.loading = true
    q.progress_current = current
    q.progress_total = total
    render_one(bufnr, q)
  end)
end

-- ── Section management ─────────────────────────────────────────────────

local function remove_section(bufnr, q)
  local state = get_state(bufnr)

  -- Remove any entries we registered in the (older) global source_map for this query
  if q.abs_lines and state.source_map then
    for _, abs in ipairs(q.abs_lines) do state.source_map[abs] = nil end
    q.abs_lines = nil
  end

  -- Compute the current region (prefer extmark-derived positions so shifts are handled).
  local start_line, end_line
  local qrow = query_row_0(bufnr, q)
  if qrow and q._lines_count then
    start_line = qrow + 3
    end_line = start_line + q._lines_count - 1
  elseif q.region then
    start_line = q.region.start_line
    end_line   = q.region.end_line
  else
    return
  end

  -- Remove the lines from the buffer
  with_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, {})
  end)

  -- Clear stored display bookkeeping
  q.region = nil
  q.header_abs = nil
  q.header_buttons = nil
  q._lines_count = nil
  q.smap = nil
end

local function remove_all_sections(bufnr)
  local state = get_state(bufnr)
  -- Collect sections with their current absolute start rows (compute from extmarks
  -- when possible so we remove bottom-to-top correctly even when things shifted).
  local with_rows = {}
  for _, q in ipairs(state.queries) do
    local qrow = query_row_0(bufnr, q)
    local s0
    if qrow and q._lines_count then
      s0 = qrow + 3
    elseif q.region then
      s0 = q.region.start_line
    end
    if s0 then with_rows[#with_rows + 1] = { q = q, s0 = s0 } end
  end
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
  -- Show the query string in the toggle button (truncated to 40 chars)
  local query_display = q.query_str:sub(1, 40)
  if #q.query_str > 40 then query_display = query_display .. "…" end
  push("[" .. query_display .. "]",   "toggle_render")
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
    local display_page = leaf_name(r.source_page)
    local suffix
    local content
    if r.is_page then
      suffix = r.date and (" · " .. r.date) or ""
      content = truncate(display_page, 46)
    else
      suffix = display_page .. (r.date and (" · " .. r.date) or "")
      content = truncate(r.content, 46)
    end
    local padding = math.max(1, 58 - #content - #suffix)
    return " • " .. content .. string.rep(" ", padding) .. suffix
  end

  local function table_line(r)
    local display_page = leaf_name(r.source_page)
    local vals = {
      block = truncate(r.content,    COLUMN_WIDTHS.block),
      page  = truncate(display_page, COLUMN_WIDTHS.page),
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
    if q.loading then
      local cur = q.progress_current or 0
      local tot = q.progress_total or 100
      local bar = util.make_progress_bar(cur, tot, 20)
      add("  Loading... " .. bar)
    else
      add("  (no results)")
    end
  end

  -- Bottom separator
  add(SEP)

  return lines, smap, header_rel, header_buttons
end

-- ── Rendering ──────────────────────────────────────────────────────────

local function apply_highlights(bufnr, abs0, lines, header_rel, header_buttons, q)
  -- Mark separators quickly
  for i, line in ipairs(lines) do
    if line == SEP then
      vim.api.nvim_buf_add_highlight(bufnr, NS, "Comment", abs0 + i - 1, 0, -1)
    end
  end

  -- Header + buttons
  local hdr_abs = abs0 + header_rel - 1
  vim.api.nvim_buf_add_highlight(bufnr, NS, "Normal", hdr_abs, 0, -1)
  for _, btn in ipairs(header_buttons or {}) do
    local hl = (btn.action == "set_mode" and btn.data == q.mode) and "Bold"
            or (btn.action == "toggle_render") and "Special"
            or "Comment"
    vim.api.nvim_buf_add_highlight(bufnr, NS, hl, hdr_abs, btn.from - 1, btn.to)
  end

  -- Column picker (table mode)
  if q.mode == "table" and q.show_columns then
    for i = header_rel + 1, #lines do
      if lines[i] == SEP then break end
      vim.api.nvim_buf_add_highlight(bufnr, NS, "Comment", abs0 + i - 1, 0, -1)
      local line = lines[i]
      local mark_s, mark_e = line:find("%[.%]")
      if mark_s then
        local hl = line:sub(mark_s + 1, mark_s + 1) == "x" and "DiagnosticOk" or "Comment"
        vim.api.nvim_buf_add_highlight(bufnr, NS, hl, abs0 + i - 1, mark_s - 1, mark_e)
      end
    end
  end

  -- Column header row (first row after the picker/separator)
  if q.mode == "table" then
    for i = header_rel + 1, #lines do
      if lines[i] == SEP then
        local col_hdr_abs = abs0 + i
        if col_hdr_abs < abs0 + #lines then
          vim.api.nvim_buf_add_highlight(bufnr, NS, "Bold", col_hdr_abs, 0, -1)
        end
        break
      end
    end
  end

  -- Page name / result highlighting — highlight the whole result line
  if q.mode == "list" then
    for i, line in ipairs(lines) do
      if line:match("^ • ") and not line:match("^  %(no results%)") and not line:match("^  Loading...") then
        vim.api.nvim_buf_add_highlight(bufnr, NS, "LogseqLink", abs0 + i - 1, 0, -1)
      end
    end
  elseif q.mode == "table" then
    -- Find the column-separator line (contains '─┼─') after header, then highlight rows after it
    local col_sep_rel = nil
    for rel = header_rel + 1, #lines do
      if lines[rel] == SEP then break end
      if lines[rel]:find("─┼─", 1, true) then col_sep_rel = rel; break end
    end
    if col_sep_rel then
      for i = col_sep_rel + 1, #lines do
        if lines[i] == SEP then break end
        vim.api.nvim_buf_add_highlight(bufnr, NS, "LogseqLink", abs0 + i - 1, 0, -1)
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

render_one = function(bufnr, q)
  local qrow = query_row_0(bufnr, q)
  if not qrow then return end
  if q.hidden then 
    -- Remove the section if it exists
    if q.region then
      remove_section(bufnr, q)
    end
    return 
  end

  -- Build display lines and source map (smap: rel_idx -> action)
  local lines, smap, header_rel, header_buttons = build_display(q)

  -- Remove existing section if it exists
  if q.region then
    remove_section(bufnr, q)
  end

  -- Insert the lines into the buffer immediately after the query line
  local insert_pos = qrow + 1  -- 0-based insertion index (after query row)
  local final_lines = {""}  -- leading blank separator line
  vim.list_extend(final_lines, lines)

  with_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, insert_pos, insert_pos, false, final_lines)
  end)

  -- Set up the region
  -- `final_lines` includes a leading blank, so the first `lines[1]` lands
  -- at buffer line `insert_pos + 2` (1-indexed). Use that as `start_line`.
  local start_line = insert_pos + 2   -- 1-indexed first visible display line (lines[1])
  local end_line = insert_pos + #final_lines
  q.region = { start_line = start_line, end_line = end_line }

  local state = get_state(bufnr)

  -- Store per-query source map (relative indices) and display length so we can
  -- recompute absolute positions from the query extmark when needed.
  q.smap = smap
  q._lines_count = #final_lines
  q.header_rel = header_rel
  q.header_buttons = header_buttons
  q.region = { start_line = start_line, end_line = end_line }

  -- Apply highlights
  apply_highlights(bufnr, start_line, lines, header_rel, header_buttons, q)
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
  execute_query(bufnr, q)
end

--- Re-render all queries in the buffer (called on BufReadPost and after save).
--- Optionally accepts preserved_state to restore query results across write cycles.
function M.render_all(bufnr, preserved_state)
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
    
    -- Restore preserved state if available for this query
    local preserved = preserved_state and preserved_state[f.query_str]
    
    local q = {
      query_mark         = vim.api.nvim_buf_set_extmark(bufnr, NS, f.row_0, 0, {}),
      query_str          = f.query_str,
      ast                = ast,
      parse_error        = err,
      region             = nil,
      mode               = preserved and preserved.mode or "list",
      columns            = preserved and vim.deepcopy(preserved.columns) or vim.deepcopy(DEFAULT_COLUMNS),
      show_columns       = preserved and preserved.show_columns or false,
      hidden             = preserved and preserved.hidden or true,  -- Start with query toggled off
      results            = preserved and preserved.results or nil,   -- Restore results if available
      loading            = preserved and preserved.loading or false,
      header_rel         = nil,
      header_buttons     = nil,
      header_abs         = nil,
    }
    state.queries[#state.queries + 1] = q

    if ast then
      -- Don't execute by default; just render the collapsed view
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then render_one(bufnr, q) end
      end)
    else
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then render_one(bufnr, q) end
      end)
    end
  end
end

-- ── Navigation & interaction ───────────────────────────────────────────

--- True if lnum (1-indexed) is on a query line or within a query results section.
function M.in_any_region(bufnr, lnum)
  local state = get_state(bufnr)
  for _, q in ipairs(state.queries) do
    -- Check if on the query line
    local qrow = query_row_0(bufnr, q)
    if qrow and lnum == qrow + 1 then return true end
    
    -- Check if in the results section (compute current region from extmark)
    if qrow and q._lines_count then
      local start_line = qrow + 3
      local end_line = start_line + q._lines_count - 1
      if lnum >= start_line and lnum <= end_line then return true end
    elseif q.region and lnum >= q.region.start_line and lnum <= q.region.end_line then
      return true
    end
  end
  return false
end

local function handle_button(bufnr, q, action, data)
  if action == "toggle_render" then
    q.hidden = not q.hidden
    if q.hidden then
      remove_section(bufnr, q)
      q.loading = false
      return
    end

    -- If no results yet, show loading and execute the query; otherwise just render.
    if not q.results and q.ast then
      q.loading = true
      render_one(bufnr, q)
      execute_query(bufnr, q)
    else
      render_one(bufnr, q)
    end
    return
  end

  if action == "set_mode" then
    update_and_render(bufnr, q, function()
      q.mode = data
      q.show_columns = false
    end)
    return
  end

  if action == "toggle_col_picker" then
    update_and_render(bufnr, q, function()
      q.show_columns = not q.show_columns
    end)
    return
  end
end

local function dispatch_smap(bufnr, q, action)
  if action.action == "navigate" then
    open_file_at(action.file, action.line)

  elseif action.action == "toggle_column" then
    update_and_render(bufnr, q, function()
      q.columns[action.column] = not q.columns[action.column]
    end)
  end
end

--- Handle <CR> inside a query section. Returns true if the press was consumed.
function M.navigate(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  if not M.in_any_region(bufnr, lnum) then return false end

  local state = get_state(bufnr)

  -- First: header buttons (per-query). Compute header position from extmark so
  -- it remains correct even if other sections shifted the buffer.
  for _, q in ipairs(state.queries) do
    local qrow = query_row_0(bufnr, q)
    if qrow and q.header_rel and lnum == (qrow + q.header_rel + 2) then
      local col = vim.api.nvim_win_get_cursor(0)[2] + 1  -- 1-indexed byte
      for _, btn in ipairs(q.header_buttons or {}) do
        if col >= btn.from and col <= btn.to then
          handle_button(bufnr, q, btn.action, btn.data)
          return true
        end
      end
      return true
    end
  end

  -- Then: per-query relative source maps. Recompute absolute rows from the
  -- query extmark so mappings don't go stale when other sections insert/remove.
  for _, q in ipairs(state.queries) do
    local qrow = query_row_0(bufnr, q)
    if qrow and q._lines_count and q.smap then
      local start_line = qrow + 3
      local end_line = start_line + q._lines_count - 1
      if lnum >= start_line and lnum <= end_line then
        local rel = lnum - start_line + 1
        local action = q.smap[rel]
        if action then
          dispatch_smap(bufnr, q, action)
          return true
        end
      end
    elseif q.region and q.smap and lnum >= q.region.start_line and lnum <= q.region.end_line then
      -- Fallback if extmark is not available
      local rel = lnum - q.region.start_line + 1
      local action = q.smap[rel]
      if action then
        dispatch_smap(bufnr, q, action)
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
        q.loading = false
      else
        -- Show loading indicator if we don't have results yet
        if not q.results and q.ast then
          q.loading = true
          render_one(bufnr, q)
          execute_query(bufnr, q)
        else
          render_one(bufnr, q)
        end
      end
      return
    end
  end
end
-- ── Buffer lifecycle ───────────────────────────────────────────────────

local function on_write_pre(bufnr)
  local state = get_state(bufnr)
  state._had_queries = #state.queries > 0
  
  -- Preserve query results/state before clearing (keyed by query string)
  state._preserved_state = {}
  for _, q in ipairs(state.queries) do
    state._preserved_state[q.query_str] = {
      results = q.results,
      mode = q.mode,
      columns = vim.deepcopy(q.columns),
      show_columns = q.show_columns,
      hidden = q.hidden,
      loading = q.loading,
    }
  end
  
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
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath ~= "" then indexer.invalidate(filepath) end

  local state = get_state(bufnr)
  if not state._had_queries then return end
  state._had_queries = false
  
  -- Pass the preserved state to render_all so it can restore results
  local preserved = state._preserved_state
  state._preserved_state = nil
  
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then M.render_all(bufnr, preserved) end
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

  if _G.logseq_toggle_query_render == nil then
    _G.logseq_toggle_query_render = function()
      require("logseq.query_ui").toggle_render_at_cursor()
    end
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

  -- Helper to bind keys that should act only when inside a query section,
  -- otherwise fall through to the original key behavior.
  local function bind_section_key(key, handler)
    vim.keymap.set("n", key, function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      if M.in_any_region(bufnr, lnum) then
        handler(bufnr, lnum)
      else
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
      end
    end, { buffer = bufnr, silent = true })
  end

  bind_section_key("r", function(b, l) refresh_at(b, l) end)
  bind_section_key("t", function(b, l) toggle_mode_at(b, l) end)
  bind_section_key("c", function(b, l) toggle_cols_at(b, l) end)

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

--- One-time global setup: when ANY vault .md file is written, invalidate its
--- cache entry so that subsequent query executions see fresh file data.
function M.setup_global()
  vim.api.nvim_create_autocmd("BufWritePost", {
    group   = vim.api.nvim_create_augroup("LogseqQueryGlobal", { clear = true }),
    pattern = "*.md",
    callback = function(ev)
      local vault = config.current.vault_path
      if not vault or not util.is_vault_file(ev.file, vault) then return end
      indexer.invalidate(ev.file)
    end,
  })
end

return M
