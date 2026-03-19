--- logseq.nvim queries (with navigation + inline editing)
--- Scans vault for tasks referencing the current page's namespace,
--- displays them in a virtual section at EOF, and supports:
---   • CR to jump to the source task
---   • Inline editing with write-back to source files on save
---   • Virtual-text source attribution (← Page Name)
---
--- Follows the same lifecycle as backlinks.lua:
---   BufWritePre  → sync edits back to source files, strip section
---   BufWritePost → re-inject section if it was visible

local config = require("logseq.config")
local M = {}

-- ── Constants ─────────────────────────────────────────────────────────

local HEADER_PATTERN = "^── Queries.*──$"
local SEPARATOR = ""

local todo_states = { "TODO", "DOING", "WAITING" }

-- ── Per-buffer state ──────────────────────────────────────────────────

M._visible = {}       -- bufnr → bool
M._region = {}        -- bufnr → { start_line, end_line }
M._source_map = {}    -- bufnr → { [abs_line] = { filepath, lnum, indent_prefix, original_task, source } }
M._had_queries = {}   -- bufnr → bool (for save/restore cycle)

-- ── Helpers ───────────────────────────────────────────────────────────

local function is_active_task(line)
  for _, state in ipairs(todo_states) do
    if line:match("^%s*%- " .. state .. "%s+") then
      return true
    end
  end
  return false
end

--- Check if a buffer line falls inside the queries section.
function M.in_region(bufnr, row)
  local region = M._region[bufnr]
  if not region then return false end
  return row >= region.start_line and row <= region.end_line
end

local function find_header_line(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match(HEADER_PATTERN) then return i end
  end
  return nil
end

-- ── Region recalculation (mirrors backlinks.lua) ──────────────────────
-- When text changes above the queries section, absolute line numbers shift.
-- This re-anchors _region and _source_map to the header's new position.

local function recalculate_region(bufnr)
  if not M._visible[bufnr] then return end
  local old_region = M._region[bufnr]
  if not old_region then return end

  local header_line = find_header_line(bufnr)
  if not header_line then
    M._visible[bufnr] = false
    M._region[bufnr] = nil
    M._source_map[bufnr] = nil
    return
  end

  local new_start = header_line
  if header_line > 1 then
    local prev = vim.api.nvim_buf_get_lines(bufnr, header_line - 2, header_line - 1, false)[1]
    if prev and prev:match("^%s*$") then new_start = header_line - 1 end
  end

  local new_end = vim.api.nvim_buf_line_count(bufnr)
  local shift = new_start - old_region.start_line

  if shift == 0 then
    M._region[bufnr].end_line = new_end
    return
  end

  local old_smap = M._source_map[bufnr] or {}
  local new_smap = {}
  for abs_line, info in pairs(old_smap) do
    new_smap[abs_line + shift] = info
  end

  M._region[bufnr] = { start_line = new_start, end_line = new_end }
  M._source_map[bufnr] = new_smap
end

-- ── File Scanner ──────────────────────────────────────────────────────

local function process_single_file(filepath, page_link, all_todos, very_next_todos)
  local f = io.open(filepath, "r")
  if not f then return end

  local content = f:read("*all")
  if not content or not content:find(page_link, 1, true) then
    f:close()
    return
  end

  f:seek("set", 0)

  local source_page = vim.fn.fnamemodify(filepath, ":t"):gsub("%.md$", ""):gsub("___", "/")
  local indent_stack = {}
  local line_num = 0

  for line in f:lines() do
    line_num = line_num + 1
    -- Match "  - " specifically (space then dash then space) to avoid matching "---" or "-x"
    local indent_str = line:match("^(%s*)%- ")
    if not indent_str then goto continue end

    local indent = #indent_str

    while #indent_stack > 0 and indent_stack[#indent_stack].indent >= indent do
      table.remove(indent_stack)
    end

    local current_is_task = is_active_task(line)
    local parent_is_task = false

    for _, parent in ipairs(indent_stack) do
      if parent.is_task then
        parent_is_task = true
        break
      end
    end

    table.insert(indent_stack, { indent = indent, is_task = current_is_task })

    if not current_is_task or not line:find(page_link, 1, true) then goto continue end

    local clean_task = vim.trim(line:gsub("^%s*%- ", ""))

    -- Defensive copy: separate table for each list to prevent shared-mutation bugs
    table.insert(all_todos, {
      task = clean_task,
      source = source_page,
      filepath = filepath,
      lnum = line_num,
      indent_prefix = indent_str, -- string of spaces, e.g. "  "
    })

    if not parent_is_task then
      table.insert(very_next_todos, {
        task = clean_task,
        source = source_page,
        filepath = filepath,
        lnum = line_num,
        indent_prefix = indent_str,
      })
    end

    ::continue::
  end

  f:close()
end

local function gather_tasks(page_name)
  local vault = config.current.vault_path
  if not vault or vault == "" then return {}, {} end

  local page_link = "[[" .. page_name .. "]]"
  local files = {}

  local function scan_dir(dir)
    if vim.fn.isdirectory(dir) == 0 then return end
    local md_files = vim.fn.glob(dir .. "/*.md", true, true)
    for _, file in ipairs(md_files) do
      table.insert(files, file)
    end
  end

  scan_dir(vault .. "/pages")
  scan_dir(vault .. "/journals")

  local all_todos = {}
  local very_next_todos = {}

  for _, filepath in ipairs(files) do
    process_single_file(filepath, page_link, all_todos, very_next_todos)
  end

  return all_todos, very_next_todos
end

-- ── Display Builder ───────────────────────────────────────────────────

local function build_section(tasks, heading_title)
  local lines = {}
  local smap = {} -- { [relative_line_index] = source_info }

  table.insert(lines, string.format("─── %d %s ───", #tasks, heading_title))

  if #tasks == 0 then
    table.insert(lines, "  (No tasks found)")
  else
    for _, t in ipairs(tasks) do
      local source_suffix = "  ← [[" .. t.source .. "]]"
      table.insert(lines, "  - " .. t.task .. source_suffix)
      smap[#lines] = {
        filepath = t.filepath,
        lnum = t.lnum,
        indent_prefix = t.indent_prefix,
        original_task = t.task,
        source = t.source,
        source_suffix = source_suffix,
      }
    end
  end

  table.insert(lines, "")
  return lines, smap
end

-- ── Inline Edit Sync ──────────────────────────────────────────────────

--- Apply a single edit to a loaded buffer. Returns true on success.
local function apply_edit_to_buffer(target_buf, edit)
  local source_lines = vim.api.nvim_buf_get_lines(target_buf, edit.lnum - 1, edit.lnum, false)
  if #source_lines == 0 then return false end

  local clean = vim.trim(source_lines[1]:gsub("^%s*%- ", ""))
  if clean ~= edit.original_task then return false end

  vim.api.nvim_buf_set_lines(target_buf, edit.lnum - 1, edit.lnum, false,
    { edit.indent_prefix .. "- " .. edit.new_task })
  return true
end

--- Apply a single edit to an in-memory file table. Returns true on success.
local function apply_edit_to_disk(file_lines, edit)
  if edit.lnum > #file_lines then return false end

  local clean = vim.trim(file_lines[edit.lnum]:gsub("^%s*%- ", ""))
  if clean ~= edit.original_task then return false end

  file_lines[edit.lnum] = edit.indent_prefix .. "- " .. edit.new_task
  return true
end

--- Compare current buffer text against stored originals and write changes back.
local function sync_edits(bufnr)
  local smap = M._source_map[bufnr]
  if not smap then return end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local edits_by_file = {}

  for abs_line, info in pairs(smap) do
    if abs_line > #buf_lines then goto next_line end

    local current_text = buf_lines[abs_line]
    -- Strip bullet prefix, then strip the appended source suffix (← [[Page]])
    local displayed_task = vim.trim(current_text:gsub("^%s*%- ", ""))
    displayed_task = displayed_task:gsub("%s*←%s*%[%[.-%]%]$", "")

    if displayed_task == info.original_task then goto next_line end

    local file_edits = edits_by_file[info.filepath] or {}
    table.insert(file_edits, {
      lnum = info.lnum,
      indent_prefix = info.indent_prefix,
      new_task = displayed_task,
      original_task = info.original_task,
    })
    edits_by_file[info.filepath] = file_edits

    ::next_line::
  end

  -- Early exit: nothing changed
  if not next(edits_by_file) then return end

  local total_written = 0

  for filepath, edits in pairs(edits_by_file) do
    -- Sort descending so line-number edits don't shift each other
    table.sort(edits, function(a, b) return a.lnum > b.lnum end)

    local target_buf = vim.fn.bufnr(filepath)

    if target_buf ~= -1 and vim.api.nvim_buf_is_loaded(target_buf) then
      -- Buffer is open — edit via API (preserves undo)
      local buf_changed = false
      for _, edit in ipairs(edits) do
        if apply_edit_to_buffer(target_buf, edit) then
          buf_changed = true
          total_written = total_written + 1
        end
      end
      if buf_changed and vim.bo[target_buf].modified then
        vim.api.nvim_buf_call(target_buf, function()
          pcall(function() vim.cmd("silent write") end)
        end)
      end
    else
      -- Buffer not loaded — direct file I/O
      local file_lines = vim.fn.readfile(filepath)
      local file_changed = false
      for _, edit in ipairs(edits) do
        if apply_edit_to_disk(file_lines, edit) then
          file_changed = true
          total_written = total_written + 1
        end
      end
      if file_changed then
        vim.fn.writefile(file_lines, filepath)
      end
    end
  end

  if total_written > 0 then
    vim.notify(
      string.format("[logseq.nvim] %d query edit(s) synced.", total_written),
      vim.log.levels.INFO
    )
  end
end

-- ── Section Management ────────────────────────────────────────────────

function M.remove_section(bufnr)
  local header_line = find_header_line(bufnr)
  if not header_line then
    M._visible[bufnr] = false
    M._region[bufnr] = nil
    M._source_map[bufnr] = nil
    return false
  end

  local start = header_line
  if header_line > 1 then
    local prev = vim.api.nvim_buf_get_lines(bufnr, header_line - 2, header_line - 1, false)[1]
    if prev and prev:match("^%s*$") then start = header_line - 1 end
  end

  local was_modified = vim.bo[bufnr].modified
  vim.api.nvim_buf_set_lines(bufnr, start - 1, vim.api.nvim_buf_line_count(bufnr), false, {})
  vim.bo[bufnr].modified = was_modified

  M._visible[bufnr] = false
  M._region[bufnr] = nil
  M._source_map[bufnr] = nil

  local ns = vim.api.nvim_create_namespace("logseq_queries")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  return true
end

function M.render_section(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local filename = vim.fn.fnamemodify(filepath, ":t")
  local namespace = filename:match("^(.-)___")

  if not namespace then
    vim.notify("Not in a namespace. Cannot apply queries.", vim.log.levels.WARN)
    return
  end

  local query_path = config.current.vault_path .. "/pages/Query___" .. namespace .. ".md"
  local f = io.open(query_path, "r")
  if not f then
    vim.notify("No Query___" .. namespace .. ".md found.", vim.log.levels.WARN)
    return
  end

  local query_content = f:read("*all")
  f:close()

  -- Gather tasks
  local page_name = filename:gsub("%.md$", ""):gsub("___", "/")
  local all_todos, very_next_todos = gather_tasks(page_name)

  -- Build display lines from the query template
  local display_lines = { "── Queries ──" }
  local all_smap = {} -- { [rel_index_in_display_lines] = source_info }

  for line in query_content:gmatch("([^\n]*)\n?") do
    if line == "%QueryTodos%" then
      local section_lines, section_smap = build_section(all_todos, "Actions")
      local offset = #display_lines
      vim.list_extend(display_lines, section_lines)
      for rel, info in pairs(section_smap) do
        all_smap[rel + offset] = info
      end
    elseif line == "%QueryVeryNextTodos%" then
      local section_lines, section_smap = build_section(very_next_todos, "Very next actions")
      local offset = #display_lines
      vim.list_extend(display_lines, section_lines)
      for rel, info in pairs(section_smap) do
        all_smap[rel + offset] = info
      end
    elseif line ~= "" then
      table.insert(display_lines, line)
    end
  end

  -- Inject at EOF
  local was_modified = vim.bo[bufnr].modified
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local section_start = line_count + 1  -- 1-indexed first line of injected content

  local inject = { SEPARATOR }
  vim.list_extend(inject, display_lines)

  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, inject)
  vim.bo[bufnr].modified = was_modified

  -- Region tracking (1-indexed)
  M._region[bufnr] = {
    start_line = section_start,
    end_line = section_start + #inject - 1,
  }
  M._visible[bufnr] = true

  -- Build absolute source map
  M._source_map[bufnr] = {}
  local ns = vim.api.nvim_create_namespace("logseq_queries")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for rel_line, info in pairs(all_smap) do
    local abs_line = section_start + rel_line
    M._source_map[bufnr][abs_line] = info
  end

  -- Highlights — all nvim_buf_add_highlight calls use 0-indexed lines
  -- base_0 converts section_start (1-indexed) to 0-indexed base for inject[1]
  local base_0 = section_start - 1

  for i = 1, #inject do
    local line_0 = base_0 + (i - 1)
    local text = inject[i]

    if text:match(HEADER_PATTERN) then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "Title", line_0, 0, -1)
    elseif text:match("^─── .+ ───$") then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", line_0, 0, -1)
    end
  end
end

-- ── Navigation ────────────────────────────────────────────────────────

--- Jump to the source file + line of the task under cursor.
--- Called by links.lua when CR is pressed inside the queries region.
---@return boolean true if navigation happened
function M.navigate()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  if not M.in_region(bufnr, lnum) then return false end

  local smap = M._source_map[bufnr]
  if not smap or not smap[lnum] then return false end

  local target = smap[lnum]

  -- Sync any pending edits before navigating away
  sync_edits(bufnr)

  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(target.filepath))
  pcall(vim.api.nvim_win_set_cursor, 0, { target.lnum, 0 })
  return true
end

-- ── Toggle ────────────────────────────────────────────────────────────

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  if M._visible[bufnr] then
    sync_edits(bufnr)
    M.remove_section(bufnr)
  else
    M.render_section(bufnr)
  end
end

-- ── Write Lifecycle ───────────────────────────────────────────────────

local function on_write_pre(bufnr)
  if not M._visible[bufnr] then return end
  sync_edits(bufnr)
  M._had_queries[bufnr] = true
  M.remove_section(bufnr)
end

local function on_write_post(bufnr)
  if not M._had_queries[bufnr] then return end
  M._had_queries[bufnr] = nil
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.render_section(bufnr)
    end
  end)
end

-- ── Insert Guard ──────────────────────────────────────────────────────
-- Allow insert mode ONLY on task lines (those with source_map entries).
-- Headings, separators, and template lines are not editable.

local function guard_insert(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if not M.in_region(bufnr, lnum) then return end

  local smap = M._source_map[bufnr]
  if smap and smap[lnum] then return end -- task line: allow editing

  vim.cmd("stopinsert")
  vim.notify("[logseq.nvim] Only task lines are editable.", vim.log.levels.INFO)
end

-- ── Buffer Setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  vim.keymap.set("n", "<Leader>q", M.toggle, { buffer = bufnr, desc = "Logseq: Toggle Queries" })

  local group = vim.api.nvim_create_augroup("LogseqQueries_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group, buffer = bufnr,
    callback = function(ev) on_write_pre(ev.buf) end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group, buffer = bufnr,
    callback = function(ev) on_write_post(ev.buf) end,
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group, buffer = bufnr,
    callback = function(ev) guard_insert(ev.buf) end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group, buffer = bufnr,
    callback = function(ev)
      if M._visible[ev.buf] then recalculate_region(ev.buf) end
    end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group, buffer = bufnr,
    callback = function(ev)
      M._visible[ev.buf] = nil
      M._region[ev.buf] = nil
      M._source_map[ev.buf] = nil
      M._had_queries[ev.buf] = nil
    end,
  })
end

return M
