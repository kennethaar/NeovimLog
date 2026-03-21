--- logseq.nvim zoom
--- Zoom into a block (Logseq-style): hide all content outside the focused
--- block and its children. A breadcrumb trail in the winbar lets you zoom
--- back out step by step.

local parser = require("logseq.parser")
local util   = require("logseq.util")

local M = {}

local CRUMB_MAX = 20

-- Lookup set built from the canonical todo-state list in util.
local _TODO = {}
for _, s in ipairs(util.todo_states) do _TODO[s] = true end

-- Per-buffer zoom stack.
-- entry: { content, block_id, line_start, line_end, ancestors }
-- block_id is the Logseq `id::` property value (may be nil for blocks without one).
-- line_start/line_end are stored as a fallback when no block_id is available.
local _stacks = {}

-- ── Private helpers ───────────────────────────────────────────────────

--- Trim a block content string for breadcrumb display.
---@param content string
---@param maxlen integer
---@return string
local function short(content, maxlen)
  local s = content
    :gsub("%[%[(.-)%]%]", "%1")
    :gsub("^(%u+)%s+", function(w) return _TODO[w] and "" or w .. " " end)
    :gsub("#[%w_%-/]+%s*", "")
    :gsub("%s+", " ")
    :match("^%s*(.-)%s*$") or ""
  if #s > maxlen then s = s:sub(1, maxlen - 1) .. "…" end
  return s
end

--- Return the decoded page title for a buffer (uses util to avoid duplication).
---@param bufnr integer
---@return string
local function page_title_for(bufnr)
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
  return util.decode_filename(filename)
end

--- Build the ancestor path list: [page_title, grandparent_content, ..., parent_content].
---@param block LogseqBlock
---@param bufnr integer
---@return string[]
local function ancestor_path(block, bufnr)
  local ancs = {}
  local b = block.parent
  while b do
    table.insert(ancs, 1, b.content)
    b = b.parent
  end
  local path = { page_title_for(bufnr) }
  vim.list_extend(path, ancs)
  return path
end

--- Re-resolve a stack entry's current line range.
--- Uses the stored block_id to find the block in the current parse tree,
--- falling back to the stored line numbers when no id is available.
---@param entry table
---@param bufnr integer
---@return integer line_start
---@return integer line_end
local function current_lines(entry, bufnr)
  if entry.block_id then
    local parsed = parser.parse_buf(bufnr)
    for _, b in ipairs(parser.flatten(parsed.blocks)) do
      if b.properties["id"] == entry.block_id then
        return b.line_start, b.line_end
      end
    end
  end
  return entry.line_start, entry.line_end
end

--- Apply manual folds outside [line_start, line_end] in the current window.
--- Must be called with the target buffer current (always true for keymap callbacks).
---@param bufnr integer
---@param line_start integer
---@param line_end integer
local function apply_zoom_folds(bufnr, line_start, line_end)
  local total = vim.api.nvim_buf_line_count(bufnr)
  vim.opt_local.foldmethod = "manual"
  vim.cmd("normal! zE")
  if line_start > 1 then
    vim.cmd(string.format("%d,%dfold", 1, line_start - 1))
  end
  if line_end < total then
    vim.cmd(string.format("%d,%dfold", line_end + 1, total))
  end
  vim.opt_local.foldlevel = 99
  vim.api.nvim_win_set_cursor(0, { line_start, 0 })
end

--- Restore the full-page fold view and clear all zoom state for a buffer.
---@param bufnr integer
local function restore_full_view(bufnr)
  _stacks[bufnr] = nil
  vim.b[bufnr].logseq_zoomed = false
  vim.cmd("normal! zE")
  vim.opt_local.foldmethod = "expr"
  vim.opt_local.foldlevel = 99
  vim.cmd("redrawstatus!")
end

-- ── Public API ────────────────────────────────────────────────────────

--- Return the current zoom stack for a buffer (nil when not zoomed).
---@param bufnr integer|nil
---@return table|nil
function M.get_stack(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return _stacks[bufnr]
end

--- Zoom into the block under the cursor.
function M.zoom_in()
  local bufnr  = vim.api.nvim_get_current_buf()
  local parsed = parser.parse_buf(bufnr)
  local lnum   = vim.api.nvim_win_get_cursor(0)[1]
  local block  = parser.block_at_line(parsed.blocks, lnum)

  if not block then
    vim.notify("[logseq] No block under cursor to zoom into", vim.log.levels.WARN)
    return
  end

  _stacks[bufnr] = _stacks[bufnr] or {}
  table.insert(_stacks[bufnr], {
    content    = block.content,
    block_id   = block.properties["id"],
    line_start = block.line_start,
    line_end   = block.line_end,
    ancestors  = ancestor_path(block, bufnr),
  })

  vim.b[bufnr].logseq_zoomed = true
  apply_zoom_folds(bufnr, block.line_start, block.line_end)
  vim.cmd("redrawstatus!")
end

--- Zoom out one level (to the previous zoom context, or to the full page).
function M.zoom_out()
  local bufnr = vim.api.nvim_get_current_buf()
  local stack = _stacks[bufnr]

  if not stack or #stack == 0 then
    vim.notify("[logseq] Already at page level", vim.log.levels.INFO)
    return
  end

  table.remove(stack)

  if #stack == 0 then
    restore_full_view(bufnr)
    return
  end

  local prev = stack[#stack]
  local ls, le = current_lines(prev, bufnr)
  apply_zoom_folds(bufnr, ls, le)
  vim.cmd("redrawstatus!")
end

--- Reset zoom completely and restore the full-page view.
---@param bufnr integer|nil
function M.zoom_reset(bufnr)
  restore_full_view(bufnr or vim.api.nvim_get_current_buf())
end

-- ── Winbar breadcrumb ─────────────────────────────────────────────────

--- Build the breadcrumb segment shown in the winbar when zoomed.
--- Returns an empty string when not zoomed.
---@param bufnr integer
---@return string
function M.winbar_breadcrumb(bufnr)
  local stack = _stacks[bufnr]
  if not stack or #stack == 0 then return "" end

  local top   = stack[#stack]
  local parts = {}

  for _, anc in ipairs(top.ancestors) do
    parts[#parts + 1] = short(anc, CRUMB_MAX):gsub("%%", "%%%%")
  end
  parts[#parts + 1] = short(top.content, CRUMB_MAX):gsub("%%", "%%%%")

  local depth_str = #stack > 1 and (" [" .. #stack .. "]") or ""

  return "  %#Comment#" .. table.concat(parts, " > ") .. depth_str
    .. "  %@v:lua.logseq_sl_zoomout@↑out%X %@v:lua.logseq_sl_zoomreset@⌂root%X%#Normal#"
end

-- ── Buffer setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local km = require("logseq.config").current.keymaps
  local o  = { buffer = bufnr, silent = true }

  vim.keymap.set("n", km.zoom_in,    M.zoom_in,    vim.tbl_extend("force", o, { desc = "Logseq: zoom into block" }))
  vim.keymap.set("n", km.zoom_out,   M.zoom_out,   vim.tbl_extend("force", o, { desc = "Logseq: zoom out one level" }))
  vim.keymap.set("n", km.zoom_reset, M.zoom_reset, vim.tbl_extend("force", o, { desc = "Logseq: zoom reset (full page)" }))

  vim.api.nvim_create_autocmd("BufUnload", {
    buffer   = bufnr,
    once     = true,
    callback = function() _stacks[bufnr] = nil end,
  })
end

return M
