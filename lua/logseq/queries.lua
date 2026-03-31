--- logseq.nvim queries (with navigation + inline editing)
--- Scans vault for tasks referencing the current page's namespace,
--- displays them in a virtual section at EOF, and supports:
---   • CR to jump to the source task
---   • Inline editing with write-back to source files on save
---   • Virtual-text source attribution (← Page Name)

local config = require("logseq.config")
local util = require("logseq.util")

local M = {}

-- ── Constants ─────────────────────────────────────────────────────────

local HEADER_PATTERN = "^── Queries.*──$"
local SEPARATOR = ""

-- ── Per-buffer state (consolidated, audit #21 pattern) ────────────────

M._state = {} -- bufnr → { visible, region, source_map, had_queries }

local function get_state(bufnr)
  if not M._state[bufnr] then
    M._state[bufnr] = {
      visible = false,
      region = nil,
      source_map = nil,
      had_queries = false,
    }
  end
  return M._state[bufnr]
end

-- ── Helpers ───────────────────────────────────────────────────────────

local function with_modifiable(bufnr, fn)
  local was_modified   = vim.bo[bufnr].modified
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  fn()
  vim.bo[bufnr].modified   = was_modified
  vim.bo[bufnr].modifiable = was_modifiable
end

local function is_active_task(line)
  for _, state in ipairs(util.active_todo_states) do
    if line:match("^%s*%- " .. state .. "%s+") then return true end
  end
  return false
end

function M.in_region(bufnr, row)
  local state = get_state(bufnr)
  if not state.region then return false end
  return row >= state.region.start_line and row <= state.region.end_line
end

local function find_header_line(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match(HEADER_PATTERN) then return i end
  end
  return nil
end

-- ── Region recalculation ──────────────────────────────────────────────

local function recalculate_region(bufnr)
  local state = get_state(bufnr)
  if not state.visible or not state.region then return end

  local header_line = find_header_line(bufnr)
  if not header_line then
    state.visible = false
    state.region = nil
    state.source_map = nil
    return
  end

  local new_start = header_line
  if header_line > 1 then
    local prev = vim.api.nvim_buf_get_lines(bufnr, header_line - 2, header_line - 1, false)[1]
    if prev and prev:match("^%s*$") then new_start = header_line - 1 end
  end

  local new_end = vim.api.nvim_buf_line_count(bufnr)
  local shift = new_start - state.region.start_line

  if shift == 0 then
    state.region.end_line = new_end
    return
  end

  local old_smap = state.source_map or {}
  local new_smap = {}
  for abs_line, info in pairs(old_smap) do
    new_smap[abs_line + shift] = info
  end

  state.region = { start_line = new_start, end_line = new_end }
  state.source_map = new_smap
end

-- ── File Scanner ──────────────────────────────────────────────────────

local function has_task_ancestor(indent_stack)
  for _, parent in ipairs(indent_stack) do
    if parent.is_task then return true end
  end
  return false
end

local function read_file_content(filepath)
  local f = io.open(filepath, "r")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  return content
end

local function process_single_file(filepath, page_link, all_todos, very_next_todos)
  local content = read_file_content(filepath)
  if not content or not content:find(page_link, 1, true) then return end

  local source_page = vim.fn.fnamemodify(filepath, ":t"):gsub("%.md$", ""):gsub("___", "/")
  local indent_stack = {}
  local line_num = 0

  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    line_num = line_num + 1
    local indent_str = line:match("^(%s*)%- ")
    if not indent_str then goto continue end

    local indent = #indent_str
    while #indent_stack > 0 and indent_stack[#indent_stack].indent >= indent do
      table.remove(indent_stack)
    end

    local current_is_task = is_active_task(line)
    local parent_is_task  = has_task_ancestor(indent_stack)
    table.insert(indent_stack, { indent = indent, is_task = current_is_task })

    if not current_is_task or not line:find(page_link, 1, true) then goto continue end

    local entry = {
      task          = vim.trim(line:gsub("^%s*%- ", "")),
      source        = source_page,
      filepath      = filepath,
      lnum          = line_num,
      indent_prefix = indent_str,
    }
    table.insert(all_todos, entry)
    if not parent_is_task then table.insert(very_next_todos, entry) end

    ::continue::
  end
end

local function gather_tasks(page_name)
  local vault = config.current.vault_path
  if not vault or vault == "" then return {}, {} end

  local page_link = "[[" .. page_name .. "]]"
  local files = {}

  local function scan_dir(dir)
    if vim.fn.isdirectory(dir) == 0 then return end
    vim.list_extend(files, vim.fn.glob(dir .. "/*.md", true, true))
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
  local smap = {}

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

local function apply_edit_to_buffer(target_buf, edit)
  local source_lines = vim.api.nvim_buf_get_lines(target_buf, edit.lnum - 1, edit.lnum, false)
  if #source_lines == 0 then return false end

  local clean = vim.trim(source_lines[1]:gsub("^%s*%- ", ""))
  if clean ~= edit.original_task then return false end

  vim.api.nvim_buf_set_lines(target_buf, edit.lnum - 1, edit.lnum, false,
    { edit.indent_prefix .. "- " .. edit.new_task })
  return true
end

local function apply_edit_to_disk(file_lines, edit)
  if edit.lnum > #file_lines then return false end

  local clean = vim.trim(file_lines[edit.lnum]:gsub("^%s*%- ", ""))
  if clean ~= edit.original_task then return false end

  file_lines[edit.lnum] = edit.indent_prefix .. "- " .. edit.new_task
  return true
end

local function sync_edits(bufnr)
  local state = get_state(bufnr)
  if not state.source_map then return end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local edits_by_file = {}

  for abs_line, info in pairs(state.source_map) do
    if abs_line > #buf_lines then goto next_line end

    local current_text = buf_lines[abs_line]
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

  if not next(edits_by_file) then return end

  local total_written = 0

  for filepath, edits in pairs(edits_by_file) do
    table.sort(edits, function(a, b) return a.lnum > b.lnum end)

    local target_buf = vim.fn.bufnr(filepath)

    if target_buf ~= -1 and vim.api.nvim_buf_is_loaded(target_buf) then
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
  local state = get_state(bufnr)
  sync_edits(bufnr)
  local header_line = find_header_line(bufnr)
  if not header_line then
    state.visible = false
    state.region = nil
    state.source_map = nil
    return false
  end

  local start = header_line
  if header_line > 1 then
    local prev = vim.api.nvim_buf_get_lines(bufnr, header_line - 2, header_line - 1, false)[1]
    if prev and prev:match("^%s*$") then start = header_line - 1 end
  end

  with_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, start - 1, vim.api.nvim_buf_line_count(bufnr), false, {})
  end)

  state.visible = false
  state.region = nil
  state.source_map = nil

  local ns = vim.api.nvim_create_namespace("logseq_queries")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  return true
end

--- Resolve query_path and page_name for the given buffer.
--- For namespace pages: uses Query___Namespace.md.
--- For journal pages: falls back to Query___YEAR.md (e.g. Query___2026.md).
--- Returns query_path, page_name — or nil, nil if no query file applies.
local function resolve_query_file(filepath)
  local vault = config.current.vault_path or ""
  local filename = vim.fn.fnamemodify(filepath, ":t")
  local namespace = filename:match("^(.-)___")

  if namespace then
    local qpath = vault .. "/pages/Query___" .. namespace .. ".md"
    local page  = util.decode_filename(filename)
    return qpath, page
  end

  -- Journal page: try Query___YEAR.md
  local year = filename:match("^(%d%d%d%d)[_%-]")
  if year then
    local qpath = vault .. "/pages/Query___" .. year .. ".md"
    local page  = require("logseq.indexer").page_name_from_file(filepath)
                  or filename:gsub("%.md$", ""):gsub("_", "-")
    return qpath, page
  end

  return nil, nil
end

function M.render_section(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local query_path, page_name = resolve_query_file(filepath)

  if not query_path then
    vim.notify("Not in a namespace or dated journal. Cannot apply queries.", vim.log.levels.WARN)
    return
  end

  local f = io.open(query_path, "r")
  if not f then
    vim.notify("No " .. vim.fn.fnamemodify(query_path, ":t") .. " found.", vim.log.levels.WARN)
    return
  end

  local query_content = f:read("*all")
  f:close()
  local all_todos, very_next_todos = gather_tasks(page_name)

  local display_lines = { "── Queries ──" }
  local all_smap = {}

  local function append_section(tasks, heading)
    local section_lines, section_smap = build_section(tasks, heading)
    local offset = #display_lines
    vim.list_extend(display_lines, section_lines)
    for rel, info in pairs(section_smap) do all_smap[rel + offset] = info end
  end

  local normalized = query_content:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in normalized:gmatch("[^\n]+") do
    if     line == "%QueryTodos%"         then append_section(all_todos,       "Actions")
    elseif line == "%QueryVeryNextTodos%" then append_section(very_next_todos, "Very next actions")
    elseif line ~= ""                     then table.insert(display_lines, line)
    end
  end

  local state = get_state(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local section_start = line_count + 1

  local inject = { SEPARATOR }
  vim.list_extend(inject, display_lines)

  with_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, inject)
  end)

  state.region = {
    start_line = section_start,
    end_line = section_start + #inject - 1,
  }
  state.visible = true

  state.source_map = {}
  local ns = vim.api.nvim_create_namespace("logseq_queries")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for rel_line, info in pairs(all_smap) do
    local abs_line = section_start + rel_line
    state.source_map[abs_line] = info
  end

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

function M.navigate()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  if not M.in_region(bufnr, lnum) then return false end

  local state = get_state(bufnr)
  if not state.source_map or not state.source_map[lnum] then return false end

  local target = state.source_map[lnum]
  sync_edits(bufnr)

  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(target.filepath))
  pcall(vim.api.nvim_win_set_cursor, 0, { target.lnum, 0 })
  return true
end

-- ── Toggle ────────────────────────────────────────────────────────────

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = get_state(bufnr)
  if state.visible then
    M.remove_section(bufnr)
  else
    M.render_section(bufnr)
  end
end

-- ── Write Lifecycle ───────────────────────────────────────────────────

local function on_write_pre(bufnr)
  local state = get_state(bufnr)
  if not state.visible then return end
  state.had_queries = true
  M.remove_section(bufnr)
end

local function on_write_post(bufnr)
  local state = get_state(bufnr)
  if not state.had_queries then return end
  state.had_queries = false
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local ok, panels = pcall(require, "logseq.panels")
    if ok then panels.close_others(bufnr, "queries") end
    M.render_section(bufnr)
  end)
end

-- ── Insert Guard ──────────────────────────────────────────────────────

local function guard_insert(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if not M.in_region(bufnr, lnum) then return end

  local state = get_state(bufnr)
  if state.source_map and state.source_map[lnum] then return end

  vim.cmd("stopinsert")
  vim.notify("[logseq.nvim] Only task lines are editable.", vim.log.levels.INFO)
end

-- ── Buffer Setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
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
      local state = get_state(ev.buf)
      if state.visible then recalculate_region(ev.buf) end
    end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group, buffer = bufnr,
    callback = function(ev)
      M._state[ev.buf] = nil
    end,
  })
end

return M
