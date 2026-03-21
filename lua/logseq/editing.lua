--- logseq.nvim editing
--- Smart Enter, property insertion, TODO cycling, Tab indent/outdent,
--- cursor snapping, and region guards.
--- Handlers are named module functions; setup_buf only binds keymaps (audit #23).

local parser = require("logseq.parser")
local util = require("logseq.util")

local M = {}

-- ── Helpers ──────────────────────────────────────────────────────────

local function indent_size()
  return require("logseq.config").current.indent_size or 2
end

--- After vertical movement, snap cursor to just after "- " on bullet lines.
local _snapping = false
local function snap_to_bullet()
  if _snapping then return end
  local line = vim.api.nvim_get_current_line()
  local prefix = line:match("^(%s*%- )")
  if not prefix then return end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  if col < #prefix then
    _snapping = true
    vim.api.nvim_win_set_cursor(0, { row, #prefix })
    _snapping = false
  end
end

--- Returns true if cursor is in backlinks or queries region (read-only guard).
local function in_protected_region(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  local bl_ok, backlinks = pcall(require, "logseq.backlinks")
  if bl_ok and backlinks.in_region(bufnr, lnum) then return true end

  local q_ok, queries = pcall(require, "logseq.queries")
  if q_ok and queries.in_region(bufnr, lnum) then return true end

  return false
end

--- Check if lnum is in the page-properties region (before first bullet).
local function in_page_properties(lnum)
  local parsed = parser.parse_buf()
  if #parsed.blocks == 0 then return true end
  return lnum < parsed.blocks[1].line_start
end

-- ── TODO Cycling ─────────────────────────────────────────────────────

function M.cycle_todo()
  local parsed = parser.parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if not block then return end

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local line = lines[block.line_start]
  local indent_str, rest = line:match("^(%s*)%- (.*)$")
  if not indent_str then return end

  local states = util.todo_states
  local current_state, content_after = nil, rest

  for _, state in ipairs(states) do
    local after = rest:match("^" .. state .. "%s*(.*)")
    if after then
      current_state, content_after = state, after
      break
    end
  end

  local next_state = nil
  if current_state then
    for i, state in ipairs(states) do
      if state == current_state then
        next_state = states[i + 1] -- nil if at end → strips state
        break
      end
    end
  else
    next_state = states[1]
  end

  local new_line
  if next_state then
    new_line = indent_str .. "- " .. next_state .. " " .. content_after
  else
    new_line = indent_str .. "- " .. content_after
  end
  vim.api.nvim_buf_set_lines(0, block.line_start - 1, block.line_start, false, { new_line })
end

-- ── Smart Enter (Insert Mode) ────────────────────────────────────────
-- Creates a new sibling block after the current block's full range.
-- Handles text splitting mid-line and completion popup confirmation.

function M.smart_enter(bufnr)
  if in_protected_region(bufnr) then
    vim.cmd("stopinsert")
    return
  end

  -- Completion popup open → confirm selection
  if vim.fn.pumvisible() == 1 then
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<C-y>", true, false, true), "n", true)
    return
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local parsed = parser.parse_buf()
  local block = parser.block_at_line(parsed.blocks, row)

  local ind = 0
  -- insert_after is 1-indexed line number; nvim_buf_set_lines(0, N, N, ...)
  -- inserts *after* 1-indexed line N (0-indexed index N = after line N).
  local insert_after = row

  if block then
    ind = block.indent
    insert_after = block.line_end
  end

  local indent_str = string.rep(" ", ind)

  -- Text splitting: if cursor is mid-content, move trailing text to new block
  local text_after = ""
  local bullet_prefix = line:match("^(%s*%- )")
  if bullet_prefix and col >= #bullet_prefix and col < #line then
    text_after = line:sub(col + 1)
    vim.api.nvim_set_current_line(line:sub(1, col))
    -- Buffer changed — re-parse to get correct line_end
    parsed = parser.parse_buf()
    block = parser.block_at_line(parsed.blocks, row)
    if block then insert_after = block.line_end end
  end

  local new_line = indent_str .. "- " .. text_after
  vim.api.nvim_buf_set_lines(0, insert_after, insert_after, false, { new_line })
  vim.api.nvim_win_set_cursor(0, { insert_after + 1, #indent_str + 2 })
end

-- ── Smart Property: Shift+Enter ──────────────────────────────────────
-- Inserts a continuation/property line (no bullet), after the last
-- consecutive property/continuation line but before children (audit #10).

function M.smart_property(bufnr)
  if in_protected_region(bufnr) then
    vim.cmd("stopinsert")
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local parsed = parser.parse_buf()
  local block = parser.block_at_line(parsed.blocks, row)

  local ind = 0
  local insert_after = row

  if block then
    ind = block.indent + indent_size()
    -- Walk from bullet line to find last property/continuation before first child
    insert_after = block.line_start
    for i = block.line_start + 1, block.line_end do
      local l = lines[i]
      if l:match("^%s*%- ") then break end -- child bullet → stop
      insert_after = i
    end
  end

  local indent_str = string.rep(" ", ind)
  vim.api.nvim_buf_set_lines(0, insert_after, insert_after, false, { indent_str })
  vim.api.nvim_win_set_cursor(0, { insert_after + 1, #indent_str })
end

-- ── O: New Sibling Above (Normal Mode) ───────────────────────────────
-- (audit #14) Falls back to native O when in page-properties region.

function M.new_sibling_above(bufnr)
  if in_protected_region(bufnr) then return end

  local row = vim.api.nvim_win_get_cursor(0)[1]

  -- Fall back to native O in page-properties region (audit #14)
  if in_page_properties(row) then
    vim.cmd("normal! O")
    return
  end

  local parsed = parser.parse_buf()
  local block = parser.block_at_line(parsed.blocks, row)

  local ind = 0
  local insert_before = row

  if block then
    ind = block.indent
    insert_before = block.line_start
  end

  local new_line = string.rep(" ", ind) .. "- "
  vim.api.nvim_buf_set_lines(0, insert_before - 1, insert_before - 1, false, { new_line })
  vim.api.nvim_win_set_cursor(0, { insert_before, #new_line })
  vim.cmd("startinsert!")
end

-- ── Parser-Aware Tab Indent (audit #13) ──────────────────────────────
-- Uses the parser to shift the current block's subtree, consistent
-- with normal-mode Tab behavior.

function M.insert_tab_indent(bufnr)
  if in_protected_region(bufnr) then return end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local motions_ok, motions = pcall(require, "logseq.motions")
  if motions_ok and motions.demote then
    motions.demote()
    -- Restore cursor to roughly the same position
    pcall(vim.api.nvim_win_set_cursor, 0, { row, col + indent_size() })
  else
    -- Fallback to Vim's built-in
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-t>", true, false, true), "n", true)
  end
end

function M.insert_tab_outdent(bufnr)
  if in_protected_region(bufnr) then return end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local motions_ok, motions = pcall(require, "logseq.motions")
  if motions_ok and motions.promote then
    motions.promote()
    pcall(vim.api.nvim_win_set_cursor, 0, { row, math.max(0, col - indent_size()) })
  else
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "n", true)
  end
end

-- ── Buffer Setup (audit #23: only keymaps and autocmds) ──────────────

function M.setup_buf(bufnr)
  local map = vim.keymap.set
  local sz = indent_size()

  -- Smart Enter
  map("i", "<CR>", function() M.smart_enter(bufnr) end,
    { buffer = bufnr, desc = "Logseq: new sibling (insert)" })

  -- Smart Property
  map("i", "<S-CR>", function() M.smart_property(bufnr) end,
    { buffer = bufnr, desc = "Logseq: new property line" })

  -- O: New sibling above (with page-properties fallback)
  map("n", "O", function() M.new_sibling_above(bufnr) end,
    { buffer = bufnr, desc = "Logseq: new sibling above" })

  -- o: Guarded new_sibling from motions
  local motions_ok, motions = pcall(require, "logseq.motions")
  if motions_ok and motions.new_sibling then
    map("n", require("logseq.config").current.keymaps.new_sibling, function()
      if in_protected_region(bufnr) then return end
      motions.new_sibling()
    end, { buffer = bufnr, silent = true, desc = "Logseq: new sibling (guarded)" })
  end

  -- Vertical movement snapping (normal mode)
  for _, key in ipairs({ "j", "<Down>" }) do
    map("n", key, function()
      vim.cmd("normal! " .. vim.v.count1 .. "j")
      snap_to_bullet()
    end, { buffer = bufnr, silent = true, desc = "Logseq: down + snap" })
  end

  for _, key in ipairs({ "k", "<Up>" }) do
    map("n", key, function()
      vim.cmd("normal! " .. vim.v.count1 .. "k")
      snap_to_bullet()
    end, { buffer = bufnr, silent = true, desc = "Logseq: up + snap" })
  end

  -- Vertical movement snapping (insert mode)
  local last_insert_row = nil
  local snap_group = vim.api.nvim_create_augroup("LogseqSnap_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = snap_group,
    buffer = bufnr,
    callback = function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if last_insert_row and row ~= last_insert_row then
        vim.schedule(snap_to_bullet)
      end
      last_insert_row = row
    end,
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = snap_group,
    buffer = bufnr,
    callback = function()
      last_insert_row = vim.api.nvim_win_get_cursor(0)[1]
    end,
  })

  -- TODO cycling
  map("n", "<C-t>", M.cycle_todo, { buffer = bufnr, desc = "Logseq: cycle TODO" })
  map("i", "<C-t>", function() M.cycle_todo(); vim.cmd("startinsert!") end, { buffer = bufnr })

  -- Tab indent/outdent (audit #13: parser-aware in insert mode)
  map("i", "<Tab>", function() M.insert_tab_indent(bufnr) end, { buffer = bufnr, desc = "Logseq: indent block" })
  map("i", "<S-Tab>", function() M.insert_tab_outdent(bufnr) end, { buffer = bufnr, desc = "Logseq: outdent block" })
  map("n", "<Tab>", ">>", { buffer = bufnr })
  map("n", "<S-Tab>", "<<", { buffer = bufnr })

  -- Buffer options (audit #24: use config.indent_size)
  vim.bo[bufnr].shiftwidth = sz
  vim.bo[bufnr].tabstop = sz
  vim.bo[bufnr].expandtab = true
  vim.bo[bufnr].softtabstop = sz
end

return M
