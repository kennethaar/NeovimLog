--- logseq.nvim motions
--- Block-level navigation and manipulation.
--- Every operation that needs the tree calls parser.parse() fresh (no caching).

local parser = require("logseq.parser")

local M = {}

--- Parse the current buffer.
---@return ParseResult
local function parse_buf()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return parser.parse(lines), lines
end

--- Move cursor to a 1-indexed line.
---@param lnum integer
local function jump(lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
end

-- ── Navigation ────────────────────────────────────────────────────────

function M.next_sibling()
  local parsed = parse_buf()
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
  local parsed = parse_buf()
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
  local parsed = parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if block and block.parent then
    jump(block.parent.line_start)
  end
end

function M.first_child()
  local parsed = parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if block and #block.children > 0 then
    jump(block.children[1].line_start)
  end
end

-- ── Block move (swap with sibling) ───────────────────────────────────

function M.move_down()
  local parsed, lines = parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if not block then return end

  local sibs = parser.siblings(block, parsed.blocks)
  local idx = parser.sibling_index(block, sibs)
  if not idx or idx >= #sibs then return end

  local next_sib = sibs[idx + 1]

  -- Extract line ranges (1-indexed, inclusive)
  local a_s, a_e = block.line_start, block.line_end
  local b_s, b_e = next_sib.line_start, next_sib.line_end

  local a_lines = vim.list_slice(lines, a_s, a_e)
  local b_lines = vim.list_slice(lines, b_s, b_e)

  -- Replace entire span [a_s, b_e] with B then A
  local replacement = {}
  vim.list_extend(replacement, b_lines)
  vim.list_extend(replacement, a_lines)

  vim.api.nvim_buf_set_lines(0, a_s - 1, b_e, false, replacement)
  jump(a_s + #b_lines)
end

function M.move_up()
  local parsed, lines = parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
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

--- Count leading whitespace.
---@param line string
---@return integer
local function leading_ws(line)
  local s = line:match("^(%s*)")
  return s and #s or 0
end

--- Shift every line in a block's range by delta spaces.
---@param delta integer  +2 to demote, -2 to promote
local function shift_indent(delta)
  local parsed, lines = parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if not block then return end

  -- Don't promote past column 0
  if block.indent + delta < 0 then return end

  local s, e = block.line_start, block.line_end
  local new_lines = {}

  for i = s, e do
    local line = lines[i]
    if delta > 0 then
      new_lines[#new_lines + 1] = string.rep(" ", delta) .. line
    else
      -- Remove up to |delta| leading spaces
      local to_remove = math.min(math.abs(delta), leading_ws(line))
      new_lines[#new_lines + 1] = line:sub(to_remove + 1)
    end
  end

  vim.api.nvim_buf_set_lines(0, s - 1, e, false, new_lines)
end

function M.demote()
  -- Don't allow indenting deeper than one level past parent
  local parsed = parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  if not block then return end

  -- Find previous sibling — can only become child of the block above
  local sibs = parser.siblings(block, parsed.blocks)
  local idx = parser.sibling_index(block, sibs)
  if not idx or idx <= 1 then return end -- no sibling above to become child of

  shift_indent(2)
end

function M.promote()
  shift_indent(-2)
end

-- ── New sibling ──────────────────────────────────────────────────────

function M.new_sibling()
  local parsed = parse_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)

  local indent = 0
  local insert_after = lnum

  if block then
    indent = block.indent
    insert_after = block.line_end
  end

  local new_line = string.rep(" ", indent) .. "- "
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