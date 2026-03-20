--- logseq.nvim backlinks (Linked References)

local config = require("logseq.config")
local indexer = require("logseq.indexer")

local M = {}

-- ── Constants ─────────────────────────────────────────────────────────

local HEADER_PATTERN = "^── .*Linked References?.* ──$"
local SEPARATOR = ""

-- ── State (audit #21: single table per buffer) ────────────────────────

M._state = {} -- bufnr → { visible, region, source_map, page_name, had_backlinks }

local function get_state(bufnr)
  if not M._state[bufnr] then
    M._state[bufnr] = {
      visible = false,
      region = nil,
      source_map = nil,
      page_name = nil,
      had_backlinks = false,
    }
  end
  return M._state[bufnr]
end

-- ── Helpers ───────────────────────────────────────────────────────────

local function get_page_name(bufnr)
  local state = get_state(bufnr)
  if state.page_name then return state.page_name end
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return nil end
  local page_name = indexer.page_name_from_file(filepath)
  if page_name then state.page_name = page_name end
  return page_name
end

function M.in_region(bufnr, lnum)
  local state = get_state(bufnr)
  if not state.region then return false end
  return lnum >= state.region.start_line and lnum <= state.region.end_line
end

local function find_header_line(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match(HEADER_PATTERN) then return i end
  end
  return nil
end

local function recalculate_region(bufnr)
  local state = get_state(bufnr)
  if not state.visible then return end
  if not state.region then return end

  local header_line = find_header_line(bufnr)
  if not header_line then
    state.visible = false
    state.region = nil
    state.source_map = nil
    return
  end

  local new_start = header_line
  if header_line > 1 then
    local maybe_sep = vim.api.nvim_buf_get_lines(bufnr, header_line - 2, header_line - 1, false)[1]
    if maybe_sep and maybe_sep:match("^%s*$") then new_start = header_line - 1 end
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

local function make_progress_bar(current, total, width)
  width = width or 20
  local ratio = total > 0 and (current / total) or 1
  local filled = math.floor(ratio * width)
  local empty = width - filled
  local pct = math.floor(ratio * 100)
  return string.format("[%s%s] %d%%", string.rep("█", filled), string.rep(" ", empty), pct)
end

-- ── Display Builder ───────────────────────────────────────────────────

local function build_display(results)
  local display = {}
  local smap = {}
  local match_lines = {}
  local total = 0

  for _, r in ipairs(results) do
    for _, cb in ipairs(r.context_blocks) do
      if cb.is_match then total = total + 1 end
    end
  end

  local ref_word = total == 1 and "Reference" or "References"
  table.insert(display, string.format("── %d Linked %s ──", total, ref_word))

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
    local group_line_count = 0
    for _, entry in ipairs(group.entries) do
      for _, cb in ipairs(entry.context_blocks) do
        if not cb.is_ancestor then group_line_count = group_line_count + 1 end
      end
    end

    table.insert(display, string.format("- [[%s]]  ⋯ %d lines", page_name, group_line_count))
    smap[#display] = { file = group.source_file, line = 1 }

    for _, entry in ipairs(group.entries) do
      for _, cb in ipairs(entry.context_blocks) do
        local indent_str = string.rep(" ", cb.indent)
        local prefix = cb.is_ancestor and "▸ " or "- "
        table.insert(display, indent_str .. prefix .. cb.text)
        local idx = #display
        smap[idx] = { file = entry.source_file, line = cb.source_line }
        if cb.is_match then match_lines[idx] = true end
      end
    end
  end

  return display, smap, match_lines
end

-- ── Rendering ─────────────────────────────────────────────────────────

function M.render_section(bufnr)
  local page_name = get_page_name(bufnr)
  if not page_name then return end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local state = get_state(bufnr)

  local was_modified = vim.bo[bufnr].modified
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local section_start = line_count + 1

  -- Initial loading state
  local initial_bar = make_progress_bar(0, 100, 20)
  local loading_lines = { SEPARATOR, string.format("── Loading Linked References... %s ──", initial_bar) }
  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, loading_lines)
  vim.bo[bufnr].modified = was_modified

  state.region = { start_line = section_start, end_line = section_start + 1 }
  state.visible = true

  local ns = vim.api.nvim_create_namespace("logseq_backlinks")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  -- Highlight the loading text (0-indexed: section_start is 1-indexed, the text is on line section_start+1-1=section_start)
  vim.api.nvim_buf_add_highlight(bufnr, ns, "Title", section_start, 0, -1)

  indexer.find_backlinks(page_name, filepath,
    -- ON COMPLETE
    function(results)
      if not vim.api.nvim_buf_is_valid(bufnr) or not state.visible then return end

      M.remove_section(bufnr)

      local display_lines, smap, match_lines = build_display(results)
      local new_line_count = vim.api.nvim_buf_line_count(bufnr)
      local new_section_start = new_line_count + 1

      local final_lines = { SEPARATOR }
      vim.list_extend(final_lines, display_lines)

      local was_mod_after = vim.bo[bufnr].modified
      vim.api.nvim_buf_set_lines(bufnr, new_line_count, new_line_count, false, final_lines)
      vim.bo[bufnr].modified = was_mod_after

      state.region = { start_line = new_section_start, end_line = new_section_start + #final_lines - 1 }
      state.visible = true

      state.source_map = {}
      local abs_match_lines = {}
      for rel_line, info in pairs(smap) do
        local abs = new_section_start + rel_line
        state.source_map[abs] = info
        if match_lines[rel_line] then table.insert(abs_match_lines, abs - 1) end
      end

      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      vim.api.nvim_buf_add_highlight(bufnr, ns, "Title", new_section_start, 0, -1)

      for abs_line, _ in pairs(state.source_map) do
        local line_0 = abs_line - 1
        local line_text = vim.api.nvim_buf_get_lines(bufnr, line_0, line_0 + 1, false)[1] or ""
        if line_text:match("^%- %[%[.+%]%]") then
          vim.api.nvim_buf_add_highlight(bufnr, ns, "LogseqLink", line_0, 0, -1)
        end
      end

      for _, line_0 in ipairs(abs_match_lines) do
        vim.api.nvim_buf_add_highlight(bufnr, ns, "Bold", line_0, 0, -1)
      end
    end,
    -- ON PROGRESS (audit #16: fix off-by-one)
    function(current, total)
      if not vim.api.nvim_buf_is_valid(bufnr) or not state.visible then return end
      if not state.region then return end

      local bar = make_progress_bar(current, total, 20)
      local progress_text = string.format("── Loading Linked References... %s ──", bar)

      -- The loading text line: region.start_line is 1-indexed.
      -- The separator is at start_line, the actual text is at start_line + 1.
      -- nvim_buf_set_lines is 0-indexed, so the text line is at (start_line + 1) - 1 = start_line.
      local text_line_0 = state.region.start_line -- 0-indexed position of the text after separator

      local was_mod = vim.bo[bufnr].modified
      pcall(vim.api.nvim_buf_set_lines, bufnr, text_line_0, text_line_0 + 1, false, { progress_text })
      vim.bo[bufnr].modified = was_mod
    end)
end

function M.remove_section(bufnr)
  local state = get_state(bufnr)
  local header_line = find_header_line(bufnr)
  if not header_line then
    state.visible = false
    state.region = nil
    state.source_map = nil
    return false
  end

  local start = header_line
  if header_line > 1 then
    local maybe_sep = vim.api.nvim_buf_get_lines(bufnr, header_line - 2, header_line - 1, false)[1]
    if maybe_sep and maybe_sep:match("^%s*$") then start = header_line - 1 end
  end

  local was_modified = vim.bo[bufnr].modified
  vim.api.nvim_buf_set_lines(bufnr, start - 1, vim.api.nvim_buf_line_count(bufnr), false, {})
  vim.bo[bufnr].modified = was_modified

  state.visible = false
  state.region = nil
  state.source_map = nil
  vim.api.nvim_buf_clear_namespace(bufnr, vim.api.nvim_create_namespace("logseq_backlinks"), 0, -1)
  return true
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = get_state(bufnr)
  if state.visible then M.remove_section(bufnr) else M.render_section(bufnr) end
end

function M.navigate()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  if not M.in_region(bufnr, lnum) then return false end
  local state = get_state(bufnr)
  if not state.source_map or not state.source_map[lnum] then return false end

  local target = state.source_map[lnum]
  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(target.file))
  if target.line and target.line > 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, { target.line, 0 })
  end
  return true
end

local function on_write_pre(bufnr)
  local state = get_state(bufnr)
  if not state.visible then return end
  state.had_backlinks = true
  M.remove_section(bufnr)
end

local function on_write_post(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath ~= "" then indexer.invalidate(filepath) end

  local state = get_state(bufnr)
  if not state.had_backlinks then return end
  state.had_backlinks = false

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then M.render_section(bufnr) end
  end)
end

local function guard_readonly(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if not M.in_region(bufnr, lnum) then return end
  vim.cmd("stopinsert")
  vim.notify("[logseq.nvim] Backlinks are read-only.", vim.log.levels.INFO)
end

function M.setup_buf(bufnr)
  local km = config.current.keymaps or {}
  local toggle_key = km.toggle_backlinks or "<leader>b"

  vim.keymap.set("n", toggle_key, M.toggle, { buffer = bufnr, silent = true })

  local group = vim.api.nvim_create_augroup("LogseqBacklinks_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePre", { group = group, buffer = bufnr, callback = function(ev) on_write_pre(ev.buf) end })
  vim.api.nvim_create_autocmd("BufWritePost", { group = group, buffer = bufnr, callback = function(ev) on_write_post(ev.buf) end })
  vim.api.nvim_create_autocmd("InsertEnter", { group = group, buffer = bufnr, callback = function(ev) guard_readonly(ev.buf) end })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group, buffer = bufnr, callback = function(ev)
      local state = get_state(ev.buf)
      if state.visible then recalculate_region(ev.buf) end
    end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group, buffer = bufnr, callback = function(ev)
      M._state[ev.buf] = nil
    end,
  })
end

return M
