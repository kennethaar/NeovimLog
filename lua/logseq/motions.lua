--- logseq.nvim motions
--- Block-level navigation and manipulation.

local parser = require("logseq.parser")

local M = {}

local function indent_size()
  return require("logseq.config").current.indent_size or 2
end

--- Move cursor to a 1-indexed line.
---@param lnum integer
local function jump(lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
end

-- ── Navigation ────────────────────────────────────────────────────────

function M.next_sibling()
  local parsed = parser.parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if not block then return end

  local sibs = parser.siblings(block, parsed.blocks)
  local idx = parser.sibling_index(block, sibs)
  if idx and idx < #sibs then
    jump(sibs[idx + 1].line_start)
  end
end

function M.prev_sibling()
  local parsed = parser.parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if not block then return end

  local sibs = parser.siblings(block, parsed.blocks)
  local idx = parser.sibling_index(block, sibs)
  if idx and idx > 1 then
    jump(sibs[idx - 1].line_start)
  end
end

function M.parent()
  local parsed = parser.parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if block and block.parent then
    jump(block.parent.line_start)
  end
end

function M.first_child()
  local parsed = parser.parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if block and #block.children > 0 then
    jump(block.children[1].line_start)
  end
end

-- ── Block move (swap with sibling) ───────────────────────────────────

--- Find the block whose bullet line is at or directly above lnum.
--- Walks backward from lnum to the nearest "^%s*%- " line, then looks up
--- that block. This is reliable for property/continuation lines regardless
--- of how far `line_end` was propagated by Pass 4 in the parser.
local function block_for_lnum(parsed, lnum)
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i = lnum, 1, -1 do
    if buf_lines[i] and buf_lines[i]:match("^%s*%- ") then
      local b = parser.block_at_line(parsed.blocks, i)
      if b then return b end
    end
  end
  return nil
end

function M.move_down()
  local parsed, lines = parser.parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = block_for_lnum(parsed, lnum)
  if not block then return end

  local sibs = parser.siblings(block, parsed.blocks)
  local idx = parser.sibling_index(block, sibs)
  if not idx or idx >= #sibs then return end

  local next_sib = sibs[idx + 1]
  local a_s, a_e = block.line_start, block.line_end
  local b_s, b_e = next_sib.line_start, next_sib.line_end

  local a_lines = vim.list_slice(lines, a_s, a_e)
  local b_lines = vim.list_slice(lines, b_s, b_e)

  local replacement = {}
  vim.list_extend(replacement, b_lines)
  vim.list_extend(replacement, a_lines)

  vim.api.nvim_buf_set_lines(0, a_s - 1, b_e, false, replacement)
  jump(a_s + #b_lines)
end

function M.move_up()
  local parsed, lines = parser.parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = block_for_lnum(parsed, lnum)
  if not block then return end

  local sibs = parser.siblings(block, parsed.blocks)
  local idx = parser.sibling_index(block, sibs)
  if not idx or idx <= 1 then return end

  local prev_sib = sibs[idx - 1]
  local a_s, a_e = prev_sib.line_start, prev_sib.line_end
  local b_s, b_e = block.line_start, block.line_end

  local a_lines = vim.list_slice(lines, a_s, a_e)
  local b_lines = vim.list_slice(lines, b_s, b_e)

  local replacement = {}
  vim.list_extend(replacement, b_lines)
  vim.list_extend(replacement, a_lines)

  vim.api.nvim_buf_set_lines(0, a_s - 1, b_e, false, replacement)
  jump(a_s)
end

-- ── Promote / demote (shift indent) ──────────────────────────────────

---@param line string
---@return integer
local function leading_ws(line)
  local s = line:match("^(%s*)")
  return s and #s or 0
end

---@param delta integer  +N to demote, -N to promote
local function shift_indent(delta)
  local parsed, lines = parser.parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if not block then return end

  if block.indent + delta < 0 then return end

  local s, e = block.line_start, block.line_end
  local new_lines = {}

  for i = s, e do
    local line = lines[i]
    if delta > 0 then
      new_lines[#new_lines + 1] = string.rep(" ", delta) .. line
    else
      local to_remove = math.min(math.abs(delta), leading_ws(line))
      new_lines[#new_lines + 1] = line:sub(to_remove + 1)
    end
  end

  vim.api.nvim_buf_set_lines(0, s - 1, e, false, new_lines)
end

function M.demote()
  local parsed = parser.parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if not block then return end

  local sibs = parser.siblings(block, parsed.blocks)
  local idx = parser.sibling_index(block, sibs)
  if not idx or idx <= 1 then return end

  shift_indent(indent_size())
end

function M.promote()
  shift_indent(-indent_size())
end

-- ── New sibling ──────────────────────────────────────────────────────

function M.new_sibling()
  local parsed = parser.parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)

  local ind = 0
  local insert_after = lnum

  if block then
    ind = block.indent
    insert_after = block.line_end
  end

  local new_line = string.rep(" ", ind) .. "- "
  vim.api.nvim_buf_set_lines(0, insert_after, insert_after, false, { new_line })
  vim.api.nvim_win_set_cursor(0, { insert_after + 1, #new_line })
  vim.cmd("startinsert!")
end

-- ── Buffer keymap setup ──────────────────────────────────────────────

function M.setup_buf()
  local km = require("logseq.config").current.keymaps
  local o = { buffer = true, silent = true }

  vim.keymap.set("n", km.next_sibling, M.next_sibling, vim.tbl_extend("force", o, { desc = "Logseq: next sibling" }))
  vim.keymap.set("n", km.prev_sibling, M.prev_sibling, vim.tbl_extend("force", o, { desc = "Logseq: prev sibling" }))
  vim.keymap.set("n", km.parent,       M.parent,       vim.tbl_extend("force", o, { desc = "Logseq: parent block" }))
  vim.keymap.set("n", km.first_child,  M.first_child,  vim.tbl_extend("force", o, { desc = "Logseq: first child" }))
  vim.keymap.set("n", km.move_down,    M.move_down,    vim.tbl_extend("force", o, { desc = "Logseq: move block down" }))
  vim.keymap.set("n", km.move_up,      M.move_up,      vim.tbl_extend("force", o, { desc = "Logseq: move block up" }))
  vim.keymap.set("n", km.demote,       M.demote,       vim.tbl_extend("force", o, { desc = "Logseq: demote (indent)" }))
  vim.keymap.set("n", km.promote,      M.promote,      vim.tbl_extend("force", o, { desc = "Logseq: promote (outdent)" }))
  vim.keymap.set("n", km.new_sibling,  M.new_sibling,  vim.tbl_extend("force", o, { desc = "Logseq: new sibling" }))
end

return M
