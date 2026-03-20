--- logseq.nvim zoom
--- Zoom into a block (Logseq-style): hide all content outside the focused
--- block and its children. A breadcrumb trail in the winbar lets you zoom
--- back out step by step.

local parser = require("logseq.parser")

local M = {}

-- Per-buffer zoom stack.
-- _stacks[bufnr] = list of { content, line_start, line_end, ancestors }
-- ancestors = list of strings (page title first, then ancestor block contents)
local _stacks = {}

-- ── Helpers ───────────────────────────────────────────────────────────

--- Trim a block content string for display in the breadcrumb.
---@param content string
---@param maxlen integer
---@return string
local function short(content, maxlen)
  -- Strip common markdown noise
  local s = content
    :gsub("%[%[(.-)%]%]", "%1")
    :gsub("^TODO%s+", ""):gsub("^DOING%s+", ""):gsub("^DONE%s+", "")
    :gsub("^WAITING%s+", ""):gsub("^CANCELLED%s+", "")
    :gsub("#[%w_%-/]+%s*", "")
    :gsub("%s+", " ")
    :match("^%s*(.-)%s*$") or ""
  if #s > maxlen then s = s:sub(1, maxlen - 1) .. "…" end
  return s
end

--- Collect the page title + ancestor block contents for a given block.
---@param block LogseqBlock
---@param bufnr integer
---@return string[]
local function ancestor_path(block, bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local filename = vim.fn.fnamemodify(filepath, ":t")
  local page_title = filename:gsub("%.md$", ""):gsub("---", "/")

  local ancs = {}
  local b = block.parent
  while b do
    table.insert(ancs, 1, b.content)
    b = b.parent
  end

  local path = { page_title }
  vim.list_extend(path, ancs)
  return path
end

--- Apply manual folds that hide every line outside [line_start, line_end].
---@param bufnr integer
---@param line_start integer
---@param line_end integer
local function apply_zoom_folds(bufnr, line_start, line_end)
  local total = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    vim.opt_local.foldmethod = "manual"
    vim.cmd("normal! zE") -- remove all existing folds

    if line_start > 1 then
      vim.cmd(string.format("%d,%dfold", 1, line_start - 1))
    end
    if line_end < total then
      vim.cmd(string.format("%d,%dfold", line_end + 1, total))
    end

    vim.opt_local.foldlevel = 99
    vim.api.nvim_win_set_cursor(0, { line_start, 0 })
  end)
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
  local bufnr = vim.api.nvim_get_current_buf()
  local parsed = parser.parse_buf(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)

  if not block then
    vim.notify("[logseq] No block under cursor to zoom into", vim.log.levels.WARN)
    return
  end

  _stacks[bufnr] = _stacks[bufnr] or {}
  table.insert(_stacks[bufnr], {
    content    = block.content,
    line_start = block.line_start,
    line_end   = block.line_end,
    ancestors  = ancestor_path(block, bufnr),
  })

  vim.b[bufnr].logseq_zoomed = true
  apply_zoom_folds(bufnr, block.line_start, block.line_end)
  vim.cmd("redrawstatus!")
end

--- Zoom out one level (to parent zoom context, or to full page if at root).
function M.zoom_out()
  local bufnr = vim.api.nvim_get_current_buf()
  local stack = _stacks[bufnr]

  if not stack or #stack == 0 then
    vim.notify("[logseq] Already at page level", vim.log.levels.INFO)
    return
  end

  table.remove(stack) -- pop current level

  if #stack == 0 then
    M.zoom_reset(bufnr)
  else
    local prev = stack[#stack]
    apply_zoom_folds(bufnr, prev.line_start, prev.line_end)
    vim.cmd("redrawstatus!")
  end
end

--- Reset zoom completely and restore the full-page view.
---@param bufnr integer|nil
function M.zoom_reset(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  _stacks[bufnr] = nil
  vim.b[bufnr].logseq_zoomed = false

  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("normal! zE") -- remove all manual folds
    vim.opt_local.foldmethod = "expr"
    vim.opt_local.foldlevel = 99
  end)

  vim.cmd("redrawstatus!")
end

--- Zoom out to a specific stack depth (0 = full page, 1 = first zoom, …).
---@param level integer
---@param bufnr integer|nil
function M.zoom_to_level(level, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local stack = _stacks[bufnr]
  if not stack then return end

  if level == 0 then
    M.zoom_reset(bufnr)
    return
  end

  while #stack > level do
    table.remove(stack)
  end

  if #stack > 0 then
    local target = stack[#stack]
    apply_zoom_folds(bufnr, target.line_start, target.line_end)
    vim.cmd("redrawstatus!")
  else
    M.zoom_reset(bufnr)
  end
end

-- ── Winbar breadcrumb ─────────────────────────────────────────────────

--- Build the breadcrumb segment shown in the winbar when zoomed.
--- Returns an empty string when not zoomed.
---@param bufnr integer
---@return string
function M.winbar_breadcrumb(bufnr)
  local stack = _stacks[bufnr]
  if not stack or #stack == 0 then return "" end

  local top = stack[#stack]
  local parts = {}

  for _, anc in ipairs(top.ancestors) do
    parts[#parts + 1] = short(anc, 18):gsub("%%", "%%%%")
  end
  parts[#parts + 1] = short(top.content, 22):gsub("%%", "%%%%")

  local crumb = table.concat(parts, " > ")

  -- Clickable "↑out" and "⌂root" buttons
  local out_btn   = "%@v:lua.logseq_sl_zoomout@↑out%X"
  local reset_btn = "%@v:lua.logseq_sl_zoomreset@⌂root%X"
  local depth = #stack
  local depth_str = depth > 1 and (" [" .. depth .. "]") or ""

  return "  %#Comment#" .. crumb .. depth_str
    .. "  " .. out_btn .. " " .. reset_btn .. "%#Normal#"
end

-- ── Buffer setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local km = require("logseq.config").current.keymaps
  local o  = { buffer = bufnr, silent = true }

  local ki = km.zoom_in    or "<leader>zi"
  local ko = km.zoom_out   or "<leader>zo"
  local kr = km.zoom_reset or "<leader>zr"

  vim.keymap.set("n", ki, M.zoom_in,    vim.tbl_extend("force", o, { desc = "Logseq: zoom into block" }))
  vim.keymap.set("n", ko, M.zoom_out,   vim.tbl_extend("force", o, { desc = "Logseq: zoom out one level" }))
  vim.keymap.set("n", kr, M.zoom_reset, vim.tbl_extend("force", o, { desc = "Logseq: zoom reset (full page)" }))

  -- Clean up zoom state when buffer is unloaded
  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = bufnr,
    once   = true,
    callback = function() _stacks[bufnr] = nil end,
  })
end

return M
