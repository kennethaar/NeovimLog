--- logseq.nvim backlinks (Linked References)
--- Toggles a read-only "Linked References" section at the bottom of the
--- buffer showing every block across the vault that references the current
--- page — including inherited references via path-refs.

local config = require("logseq.config")
local indexer = require("logseq.indexer")

local M = {}

-- ── Constants ─────────────────────────────────────────────────────────

local HEADER_PATTERN = "^── %d+ Linked References? ──$"
local SEPARATOR = ""

-- ── State ─────────────────────────────────────────────────────────────

M._visible = {}       -- bufnr → boolean
M._region = {}        -- bufnr → { start_line, end_line } (1-indexed)
M._source_map = {}    -- bufnr → { [line_number] = { file = string, line = integer } }
M._page_name = {}     -- bufnr → string (cached page name for this buffer)
M._had_backlinks = {} -- bufnr → boolean (was visible before save?)

-- ── Helpers ───────────────────────────────────────────────────────────

--- Get the page name for the current buffer.
---@param bufnr integer
---@return string|nil
local function get_page_name(bufnr)
  if M._page_name[bufnr] then return M._page_name[bufnr] end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return nil end

  local page_name = indexer.page_name_from_file(filepath)
  if page_name then
    M._page_name[bufnr] = page_name
  end
  return page_name
end

--- Check if a given line number (1-indexed) is inside the backlinks region.
---@param bufnr integer
---@param lnum integer
---@return boolean
function M.in_region(bufnr, lnum)
  local region = M._region[bufnr]
  if not region then return false end
  return lnum >= region.start_line and lnum <= region.end_line
end

--- Find the header line by scanning from the bottom of the buffer.
---@param bufnr integer
---@return integer|nil  1-indexed line number of the header
local function find_header_line(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match(HEADER_PATTERN) then
      return i
    end
  end
  return nil
end

--- Find the window displaying a given buffer, or nil.
---@param bufnr integer
---@return integer|nil
local function find_win_for_buf(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

--- Recalculate M._region by scanning for the header, shifting the source map.
--- Called when edits above the backlinks section shift line numbers.
---@param bufnr integer
local function recalculate_region(bufnr)
  if not M._visible[bufnr] then return end

  local old_region = M._region[bufnr]
  if not old_region then return end

  local header_line = find_header_line(bufnr)
  if not header_line then
    -- Header disappeared — section was somehow deleted
    M._visible[bufnr] = false
    M._region[bufnr] = nil
    M._source_map[bufnr] = nil
    return
  end

  -- Separator is the blank line immediately above the header
  local new_start = header_line
  if header_line > 1 then
    local maybe_sep = vim.api.nvim_buf_get_lines(bufnr, header_line - 2, header_line - 1, false)[1]
    if maybe_sep and maybe_sep:match("^%s*$") then
      new_start = header_line - 1
    end
  end

  local new_end = vim.api.nvim_buf_line_count(bufnr)
  local shift = new_start - old_region.start_line

  if shift == 0 then
    M._region[bufnr].end_line = new_end
    return
  end

  -- Rebuild source map with shifted keys
  local old_smap = M._source_map[bufnr] or {}
  local new_smap = {}
  for abs_line, info in pairs(old_smap) do
    new_smap[abs_line + shift] = info
  end

  M._region[bufnr] = { start_line = new_start, end_line = new_end }
  M._source_map[bufnr] = new_smap
end

-- ── Display Builder ───────────────────────────────────────────────────

--- Build display lines, source map, and match-line set from backlink results.
---@param results BacklinkResult[]
---@return string[]  display lines (header + page groups + blocks)
---@return table     smap: { [display_index] = { file, line } }
---@return table     match_lines: { [display_index] = true } for is_match blocks
local function build_display(results)
  local display = {}
  local smap = {}
  local match_lines = {}

  -- Count total matching blocks
  local total = 0
  for _, r in ipairs(results) do
    for _, cb in ipairs(r.context_blocks) do
      if cb.is_match then total = total + 1 end
    end
  end

  -- Header
  local ref_word = total == 1 and "Reference" or "References"
  table.insert(display, string.format("── %d Linked %s ──", total, ref_word))

  -- Group results by source page (preserve insertion order)
  local groups = {}
  local group_order = {}
  for _, r in ipairs(results) do
    if not groups[r.source_page] then
      groups[r.source_page] = { source_file = r.source_file, entries = {} }
      table.insert(group_order, r.source_page)
    end
    table.insert(groups[r.source_page].entries, r)
  end

  for _, page_name in ipairs(group_order) do
    local group = groups[page_name]

    -- Count non-ancestor lines in this group (for fold summary)
    local group_line_count = 0
    for _, entry in ipairs(group.entries) do
      for _, cb in ipairs(entry.context_blocks) do
        if not cb.is_ancestor then group_line_count = group_line_count + 1 end
      end
    end

    -- Page header: "- [[Page Name]]  ⋯ N lines"
    table.insert(display, string.format("- [[%s]]  ⋯ %d lines", page_name, group_line_count))
    smap[#display] = { file = group.source_file, line = 1 }

    -- Context blocks for each entry under this page
    for _, entry in ipairs(group.entries) do
      for _, cb in ipairs(entry.context_blocks) do
        local indent_str = string.rep(" ", cb.indent)
        local prefix = cb.is_ancestor and "▸ " or "- "
        table.insert(display, indent_str .. prefix .. cb.text)
        local idx = #display
        smap[idx] = { file = entry.source_file, line = cb.source_line }
        if cb.is_match then
          match_lines[idx] = true
        end
      end
    end
  end

  return display, smap, match_lines
end

-- ── Rendering ─────────────────────────────────────────────────────────

--- Render the backlinks section at the bottom of the buffer.
---@param bufnr integer
function M.render_section(bufnr)
  local page_name = get_page_name(bufnr)
  if not page_name then
    vim.notify("[logseq.nvim] Cannot determine page name for backlinks.", vim.log.levels.WARN)
    return
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local results = indexer.find_backlinks(page_name, filepath)
  local display_lines, smap, match_lines = build_display(results)

  -- Preserve modified state — appending backlinks should not dirty the buffer
  local was_modified = vim.bo[bufnr].modified

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local section_start = line_count + 1 -- 1-indexed: the separator line

  local all_lines = { SEPARATOR }
  vim.list_extend(all_lines, display_lines)
  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, all_lines)

  vim.bo[bufnr].modified = was_modified

  -- Record region
  local section_end = line_count + #all_lines
  M._region[bufnr] = { start_line = section_start, end_line = section_end }
  M._visible[bufnr] = true

  -- Build absolute source map and match set
  M._source_map[bufnr] = {}
  local abs_match_lines = {} ---@type integer[]  0-indexed line numbers for Bold highlight
  for rel_line, info in pairs(smap) do
    local abs = section_start + rel_line
    M._source_map[bufnr][abs] = info
    if match_lines[rel_line] then
      table.insert(abs_match_lines, abs - 1) -- 0-indexed for nvim API
    end
  end

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("logseq_backlinks")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  -- Header (display[1] is at buffer line section_start + 1, 0-indexed = section_start)
  vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", section_start, 0, -1)

  -- Page name lines
  for abs_line, _ in pairs(M._source_map[bufnr]) do
    local line_0 = abs_line - 1
    local line_text = vim.api.nvim_buf_get_lines(bufnr, line_0, line_0 + 1, false)[1] or ""
    if line_text:match("^%- %[%[.+%]%]") then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "LogseqLink", line_0, 0, -1)
    end
  end

  -- Matched blocks (the block that directly/inherited the reference)
  for _, line_0 in ipairs(abs_match_lines) do
    vim.api.nvim_buf_add_highlight(bufnr, ns, "Bold", line_0, 0, -1)
  end

  -- Fold page groups: close folds on page header lines
  local win = find_win_for_buf(bufnr)
  if not win then return end

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not vim.api.nvim_win_is_valid(win) then return end

    local region = M._region[bufnr]
    if not region then return end

    local saved_pos = vim.api.nvim_win_get_cursor(win)

    for i = region.start_line + 1, region.end_line do
      local lt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
      if not lt:match("^%- %[%[.+%]%]") then goto next_fold end
      pcall(function()
        vim.api.nvim_win_set_cursor(win, { i, 0 })
        vim.api.nvim_win_call(win, function() vim.cmd("normal! zc") end)
      end)
      ::next_fold::
    end

    pcall(vim.api.nvim_win_set_cursor, win, saved_pos)
  end)
end

--- Remove the backlinks section from the buffer.
---@param bufnr integer
---@return boolean  true if a section was removed
function M.remove_section(bufnr)
  local header_line = find_header_line(bufnr)
  if not header_line then
    M._visible[bufnr] = false
    M._region[bufnr] = nil
    M._source_map[bufnr] = nil
    return false
  end

  -- Include the blank separator line above the header if present
  local start = header_line
  if header_line > 1 then
    local maybe_sep = vim.api.nvim_buf_get_lines(bufnr, header_line - 2, header_line - 1, false)[1]
    if maybe_sep and maybe_sep:match("^%s*$") then
      start = header_line - 1
    end
  end

  local was_modified = vim.bo[bufnr].modified

  vim.api.nvim_buf_set_lines(bufnr, start - 1, vim.api.nvim_buf_line_count(bufnr), false, {})

  vim.bo[bufnr].modified = was_modified

  M._visible[bufnr] = false
  M._region[bufnr] = nil
  M._source_map[bufnr] = nil

  vim.api.nvim_buf_clear_namespace(bufnr, vim.api.nvim_create_namespace("logseq_backlinks"), 0, -1)
  return true
end

-- ── Toggle ────────────────────────────────────────────────────────────

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()

  if M._visible[bufnr] then
    M.remove_section(bufnr)
  else
    M.render_section(bufnr)
  end
end

-- ── Navigation ────────────────────────────────────────────────────────

--- Navigate to the source block from a backlinks display line.
---@return boolean  true if navigation happened
function M.navigate()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  if not M.in_region(bufnr, lnum) then return false end

  local smap = M._source_map[bufnr]
  if not smap or not smap[lnum] then return false end

  local target = smap[lnum]

  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(target.file))
  if target.line and target.line > 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, { target.line, 0 })
  end

  return true
end

-- ── Save Guard ────────────────────────────────────────────────────────

local function on_write_pre(bufnr)
  if not M._visible[bufnr] then return end
  M._had_backlinks[bufnr] = true
  M.remove_section(bufnr)
end

local function on_write_post(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath ~= "" then
    indexer.invalidate(filepath)
  end

  if not M._had_backlinks[bufnr] then return end
  M._had_backlinks[bufnr] = nil

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.render_section(bufnr)
    end
  end)
end

-- ── Read-Only Guard ───────────────────────────────────────────────────

local function guard_readonly(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if not M.in_region(bufnr, lnum) then return end
  vim.cmd("stopinsert")
  vim.notify("[logseq.nvim] Backlinks are read-only.", vim.log.levels.INFO)
end

-- ── Buffer Setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local km = config.current.keymaps or {}
  local toggle_key = km.toggle_backlinks or "<leader>b"

  vim.keymap.set("n", toggle_key, M.toggle, {
    buffer = bufnr,
    silent = true,
    desc = "Logseq: toggle backlinks",
  })

  local group = vim.api.nvim_create_augroup("LogseqBacklinks_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    buffer = bufnr,
    callback = function(ev) on_write_pre(ev.buf) end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = bufnr,
    callback = function(ev) on_write_post(ev.buf) end,
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = bufnr,
    callback = function(ev) guard_readonly(ev.buf) end,
  })

  -- Region drift: recalculate when edits shift line numbers above the backlinks
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function(ev)
      if M._visible[ev.buf] then
        recalculate_region(ev.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    callback = function(ev)
      M._visible[ev.buf] = nil
      M._region[ev.buf] = nil
      M._source_map[ev.buf] = nil
      M._page_name[ev.buf] = nil
      M._had_backlinks[ev.buf] = nil
    end,
  })
end

return M
