--- logseq.nvim queries (with navigation + inline editing)
--- Scans vault for tasks referencing the current page's namespace,
--- displays them in a virtual section at EOF, and supports:
---   • CR to jump to the source task
---   • Inline editing with write-back to source files on save
---   • Virtual-text source attribution (← Page Name)

local config = require("logseq.config")
local util   = require("logseq.util")
local parser = require("logseq.parser")

local M = {}

-- ── Constants ─────────────────────────────────────────────────────────

local HEADER_PATTERN = "^── Queries.*──$"
local SEPARATOR = ""
local NS = vim.api.nvim_create_namespace("logseq_queries")

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

function M.in_region(bufnr, row)
  local state = get_state(bufnr)
  if not state.region then return false end
  return row >= state.region.start_line and row <= state.region.end_line
end

-- hint: 1-indexed line to start scanning backwards from (e.g. region.start_line).
-- Falls back to full scan when hint is nil.
local function find_header_line(bufnr, hint)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local from  = hint and math.max(0, hint - 3) or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, from, total, false)
  for i = #lines, 1, -1 do
    if lines[i]:match(HEADER_PATTERN) then return from + i end
  end
  return nil
end

-- ── Region recalculation ──────────────────────────────────────────────

local function recalculate_region(bufnr)
  local state = get_state(bufnr)
  if not state.visible or not state.region then return end

  local header_line = find_header_line(bufnr, state.region.start_line)
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
-- Uses the same parser + inherited-ref logic as the indexer so that tasks
-- nested under a [[page]] bullet are found correctly.

local function read_file_content(filepath)
  local f = io.open(filepath, "r")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  return content
end

local function is_active_task_content(content_text)
  for _, state in ipairs(util.active_todo_states) do
    if content_text:match("^" .. state .. "%s+") or content_text == state then
      return true
    end
  end
  return false
end

-- Scan one file for active tasks that reference page_name.
-- Uses parser.parse + inherited link refs so tasks nested under a [[page]]
-- bullet are found (the common Logseq pattern).
local function process_single_file(filepath, page_name, all_todos, very_next_todos)
  local content = read_file_content(filepath)
  -- Quick prefix-only check: handles [[Page]] and [[Page|Alias]] alike.
  if not content or not content:find("[[" .. page_name, 1, true) then return end

  local source_page = util.decode_filename(vim.fn.fnamemodify(filepath, ":t"))
  local lines       = vim.split(content, "\n", { plain = true })
  local parsed      = parser.parse(lines)
  local flat        = parser.flatten(parsed.blocks)

  -- Propagate link refs down the ancestry chain (same logic as the indexer).
  -- Iterating flat in DFS pre-order guarantees each parent is processed first.
  local block_refs = {}
  for _, block in ipairs(flat) do
    local refs = {}
    for _, link in ipairs(block.links) do refs[link] = true end
    if block.parent and block_refs[block.parent] then
      for ref in pairs(block_refs[block.parent]) do refs[ref] = true end
    end
    block_refs[block] = refs
  end

  for _, block in ipairs(flat) do
    local refs = block_refs[block]
    if not refs or not refs[page_name] then goto continue end
    if not is_active_task_content(block.content) then goto continue end

    local orig_line  = lines[block.line_start] or ""
    local indent_str = orig_line:match("^(%s*)") or ""

    local entry = {
      task          = block.content,
      source        = source_page,
      filepath      = filepath,
      lnum          = block.line_start,
      indent_prefix = indent_str,
    }
    table.insert(all_todos, entry)

    -- Very-next: task has no task ancestor in the parent chain
    local has_task_parent = false
    local cur = block.parent
    while cur and not has_task_parent do
      if is_active_task_content(cur.content) then has_task_parent = true end
      cur = cur.parent
    end
    if not has_task_parent then table.insert(very_next_todos, entry) end

    ::continue::
  end
end

local function gather_tasks(page_name)
  local vault = config.current.vault_path
  if not vault or vault == "" then return {}, {} end

  local dirs = { vault .. "/pages", vault .. "/journals" }
  local files = {}
  for _, dir in ipairs(dirs) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.list_extend(files, vim.fn.glob(dir .. "/*.md", true, true))
    end
  end

  local all_todos, very_next_todos = {}, {}
  for _, filepath in ipairs(files) do
    local name = vim.fn.fnamemodify(filepath, ":t")
    if not name:match("^Query___") and not name:match("^Templates___") then
      process_single_file(filepath, page_name, all_todos, very_next_todos)
    end
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
  local header_line = find_header_line(bufnr, state.region and state.region.start_line)
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
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  return true
end

local function apply_display(bufnr, display_lines, all_smap)
  local state = get_state(bufnr)
  local line_count    = vim.api.nvim_buf_line_count(bufnr)
  local section_start = line_count + 1
  local inject        = { SEPARATOR }
  vim.list_extend(inject, display_lines)

  with_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, inject)
  end)

  state.region     = { start_line = section_start, end_line = section_start + #inject - 1 }
  state.visible    = true
  state.source_map = {}
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

  for rel_line, info in pairs(all_smap) do
    state.source_map[section_start + rel_line] = info
  end

  local base_0 = section_start - 1
  for i, text in ipairs(inject) do
    local line_0 = base_0 + (i - 1)
    if text:match(HEADER_PATTERN) then
      vim.api.nvim_buf_add_highlight(bufnr, NS, "Title", line_0, 0, -1)
    elseif text:match("^─── .+ ───$") then
      vim.api.nvim_buf_add_highlight(bufnr, NS, "Comment", line_0, 0, -1)
    end
  end
end

local function build_query_display(query_content, all_todos, very_next_todos)
  local display_lines = { "── Queries ──" }
  local all_smap      = {}

  local function append_section(tasks, heading)
    local section_lines, section_smap = build_section(tasks, heading)
    local offset = #display_lines
    vim.list_extend(display_lines, section_lines)
    for rel, info in pairs(section_smap) do all_smap[rel + offset] = info end
  end

  local in_codeblock = false
  for _, raw in ipairs(vim.split(query_content, "\n", { plain = true })) do
    local line = vim.trim(raw)
    if line:match("^```") or line:match("^~~~") then
      in_codeblock = not in_codeblock
      table.insert(display_lines, line)
    elseif in_codeblock then
      table.insert(display_lines, raw:gsub("\r$", ""))
    elseif line ~= "" then
      local directive = line:match("^%-?%s*(%%.+%%)%s*$")
      if directive == "%QueryTodos%" then
        append_section(all_todos, "Actions")
      elseif directive == "%QueryVeryNextTodos%" then
        append_section(very_next_todos, "Very next actions")
      else
        table.insert(display_lines, line)
      end
    end
  end

  return display_lines, all_smap
end

function M.render_section(bufnr)
  local filepath  = vim.api.nvim_buf_get_name(bufnr)
  local filename  = vim.fn.fnamemodify(filepath, ":t")
  local namespace = filename:match("^(.-)___")

  if not namespace then
    vim.notify("Not in a namespace. Cannot apply queries.", vim.log.levels.WARN)
    return
  end

  local query_path    = config.current.vault_path .. "/pages/Query___" .. namespace .. ".md"
  local query_content = read_file_content(query_path)
  if not query_content then
    vim.notify("No Query___" .. namespace .. ".md found.", vim.log.levels.WARN)
    return
  end

  -- Show a loading placeholder immediately so the user sees something while
  -- gather_tasks scans the vault (potentially hundreds of files).
  local state = get_state(bufnr)
  local line_count    = vim.api.nvim_buf_line_count(bufnr)
  local section_start = line_count + 1
  with_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false,
      { SEPARATOR, "── Queries (loading...) ──" })
  end)
  state.region  = { start_line = section_start, end_line = section_start + 1 }
  state.visible = true

  local page_name = filename:gsub("%.md$", ""):gsub("___", "/")

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) or not state.visible then return end
    M.remove_section(bufnr)

    local all_todos, very_next_todos = gather_tasks(page_name)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    local display_lines, all_smap = build_query_display(query_content, all_todos, very_next_todos)
    apply_display(bufnr, display_lines, all_smap)
  end)
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
    sync_edits(bufnr)
    M.remove_section(bufnr)
  else
    M.render_section(bufnr)
  end
end

-- ── Write Lifecycle ───────────────────────────────────────────────────

local function on_write_pre(bufnr)
  local state = get_state(bufnr)
  if not state.visible then return end
  sync_edits(bufnr)
  state.had_queries = true
  M.remove_section(bufnr)
end

local function on_write_post(bufnr)
  local state = get_state(bufnr)
  if not state.had_queries then return end
  state.had_queries = false
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if #vim.fn.win_findbuf(bufnr) == 0 then return end
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

  vim.api.nvim_create_autocmd("TextChanged", {
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
