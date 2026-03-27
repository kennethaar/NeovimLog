--- logseq.nvim zoom
--- Zoom into a block subtree: hides all content above and below it using
--- manual folds. Supports:
---   - Breadcrumb in winbar showing path to zoom root
---   - promote_or_escape: outdenting a block at the innermost level moves it
---     to just after the zoom subtree in the real document and hides it from
---     the zoomed view (it becomes a sibling of the zoom root)
---   - Guarded move_up/move_down so the zoom root cannot be displaced

local parser = require("logseq.parser")

local M = {}

--- Per-buffer zoom state table.
---@class ZoomState
---@field zoom_start       integer  1-indexed first line of the zoom subtree
---@field zoom_end         integer  1-indexed last line of the zoom subtree
---@field zoom_root_indent integer  indent of the zoom-root block
---@field breadcrumb       string   display string for winbar
---@field orig_foldmethod  string   saved foldmethod, restored on exit
---@field orig_foldtext    string   saved foldtext, restored on exit
local _state = {} -- bufnr → ZoomState

-- ── Helpers ──────────────────────────────────────────────────────────

local function indent_size()
  return require("logseq.config").current.indent_size or 2
end

--- Return the first window that is currently displaying bufnr.
local function win_for_buf(bufnr)
  local wins = vim.fn.win_findbuf(bufnr)
  return (wins and wins[1]) or nil
end

--- Walk block ancestors to build a breadcrumb string.
local function build_breadcrumb(block, bufnr)
  local parts = {}
  local b = block
  while b do
    -- Strip leading TODO keyword and trailing whitespace
    local c = b.content:gsub("^%u+%s+", ""):gsub("%s*$", "")
    if #c > 25 then c = c:sub(1, 23) .. "…" end
    table.insert(parts, 1, c)
    b = b.parent
  end
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local page = vim.fn.fnamemodify(filepath, ":t:r")
  if #page > 20 then page = page:sub(1, 18) .. "…" end
  table.insert(parts, 1, page)
  return table.concat(parts, " › ")
end

--- (Re-)create above/below manual folds and close them.
--- Must be called whenever zoom_start or zoom_end changes.
local function apply_folds(bufnr, st)
  local winid = win_for_buf(bufnr)
  if not winid then return end
  local total = vim.api.nvim_buf_line_count(bufnr)

  vim.api.nvim_win_call(winid, function()
    -- Clear any existing manual folds first
    vim.cmd("normal! zE")

    if st.zoom_start > 1 then
      vim.cmd("1," .. (st.zoom_start - 1) .. "fold")
    end

    if st.zoom_end < total then
      vim.cmd((st.zoom_end + 1) .. "," .. total .. "fold")
    end

    -- Close all newly created folds
    vim.cmd("normal! zM")
  end)
end

-- ── Public API ────────────────────────────────────────────────────────

--- True if zoom is active for bufnr.
---@param bufnr integer
---@return boolean
function M.is_active(bufnr)
  return _state[bufnr] ~= nil
end

--- Breadcrumb string for the winbar, or nil if not zoomed.
---@param bufnr integer
---@return string|nil
function M.breadcrumb(bufnr)
  local st = _state[bufnr]
  return st and st.breadcrumb or nil
end

--- Custom foldtext shown for the hidden above/below regions.
function M.foldtext()
  local bufnr = vim.api.nvim_get_current_buf()
  local st    = _state[bufnr]
  if st then
    if vim.v.foldstart < st.zoom_start then
      return "  ↑ …"
    else
      return "  ↓ …"
    end
  end
  -- Fallback to logseq fold text when not in zoom mode
  local ok, fold = pcall(require, "logseq.fold")
  return ok and fold.foldtext() or vim.fn.getline(vim.v.foldstart)
end

--- Zoom into the block at cursor. Exits any existing zoom first.
function M.enter()
  local bufnr = vim.api.nvim_get_current_buf()
  if _state[bufnr] then M.exit() end

  local lnum   = vim.api.nvim_win_get_cursor(0)[1]
  local parsed = parser.parse_buf(bufnr)
  local block  = parser.block_at_line(parsed.blocks, lnum)

  if not block then
    vim.notify("[logseq] No block at cursor", vim.log.levels.WARN)
    return
  end
  if #block.children == 0 then
    vim.notify("[logseq] Block has no children to zoom into", vim.log.levels.INFO)
    return
  end

  ---@type ZoomState
  local st = {
    zoom_start       = block.line_start,
    zoom_end         = block.line_end,
    zoom_root_indent = block.indent,
    breadcrumb       = build_breadcrumb(block, bufnr),
    orig_foldmethod  = vim.wo.foldmethod,
    orig_foldtext    = vim.wo.foldtext,
  }
  _state[bufnr] = st

  vim.wo.foldmethod = "manual"
  vim.wo.foldtext   = "v:lua.require('logseq.zoom').foldtext()"

  apply_folds(bufnr, st)
  vim.api.nvim_win_set_cursor(0, { st.zoom_start, 0 })
  vim.cmd("redrawstatus")
end

--- Exit zoom mode for the current buffer.
function M.exit()
  local bufnr = vim.api.nvim_get_current_buf()
  local st    = _state[bufnr]
  if not st then return end

  _state[bufnr] = nil

  local winid = win_for_buf(bufnr)
  if winid then
    vim.api.nvim_win_call(winid, function()
      vim.cmd("normal! zE")
    end)
  end

  vim.wo.foldmethod = (st.orig_foldmethod ~= "" and st.orig_foldmethod) or "expr"
  vim.wo.foldtext   = (st.orig_foldtext   ~= "" and st.orig_foldtext)
    or "v:lua.require('logseq.fold').foldtext()"

  vim.cmd("redrawstatus")
end

--- Promote the block at cursor, or escape it from the zoom.
---
--- Escape condition: the block is exactly one indent level inside the zoom
--- root (block.indent - indent_size == zoom_root_indent). Promoting would
--- make it a sibling of the zoom root → instead, move it to just after the
--- zoom subtree in the real document with its indent reduced, and hide it
--- inside the below-fold so it disappears from the zoomed view.
function M.promote_or_escape()
  local bufnr = vim.api.nvim_get_current_buf()
  local st    = _state[bufnr]

  if not st then
    require("logseq.motions").promote()
    return
  end

  local lnum   = vim.api.nvim_win_get_cursor(0)[1]
  local parsed = parser.parse_buf(bufnr)
  local block  = parser.block_at_line(parsed.blocks, lnum)

  if not block then
    require("logseq.motions").promote()
    return
  end

  local sz = indent_size()

  if block.indent - sz == st.zoom_root_indent then
    -- ── Escape ────────────────────────────────────────────────────────
    local b_start = block.line_start
    local b_end   = block.line_end
    local b_count = b_end - b_start + 1

    -- Collect and re-indent the block's lines (reduce by one indent_size)
    local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local escaped = {}
    for i = b_start, b_end do
      local line = all_lines[i]
      local ws   = #(line:match("^(%s*)") or "")
      escaped[#escaped + 1] = line:sub(math.min(sz, ws) + 1)
    end

    -- Remove the block from its current position inside the zoom range
    vim.api.nvim_buf_set_lines(bufnr, b_start - 1, b_end, false, {})
    st.zoom_end = st.zoom_end - b_count

    -- Insert the re-indented block immediately after the (now-shorter) zoom range.
    -- This places it as a sibling of the zoom root in the real document.
    -- It lands inside the below-fold → invisible in zoom mode.
    vim.api.nvim_buf_set_lines(bufnr, st.zoom_end, st.zoom_end, false, escaped)

    apply_folds(bufnr, st)

    -- Land cursor on the block that now occupies the vacated position (or end)
    local new_lnum = math.min(b_start, st.zoom_end)
    if new_lnum < st.zoom_start then new_lnum = st.zoom_start end
    vim.api.nvim_win_set_cursor(0, { new_lnum, 0 })
  else
    -- ── Normal promote (block stays within zoom) ──────────────────────
    require("logseq.motions").promote()
    -- Folds don't need rebuilding (promote doesn't change line count)
  end
end

-- ── Buffer Setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local km  = require("logseq.config").current.keymaps
  local sz  = indent_size()

  -- ── Zoom toggle ───────────────────────────────────────────────────
  local zoom_key = km.zoom_toggle or "<leader>z"
  vim.keymap.set("n", zoom_key, function()
    if M.is_active(bufnr) then M.exit() else M.enter() end
  end, { buffer = bufnr, silent = true, desc = "Logseq: zoom into block" })

  -- ── Promote overrides (normal + insert) ──────────────────────────
  -- These run AFTER motions.lua and editing.lua so they override those bindings.
  local promote_key = km.promote or "<<"
  vim.keymap.set("n", promote_key, function()
    if M.is_active(bufnr) then M.promote_or_escape()
    else require("logseq.motions").promote() end
  end, { buffer = bufnr, silent = true, desc = "Logseq: promote / zoom-escape" })

  vim.keymap.set("n", "<S-Tab>", function()
    if M.is_active(bufnr) then M.promote_or_escape()
    else vim.cmd("normal! <<") end
  end, { buffer = bufnr, silent = true, desc = "Logseq: outdent / zoom-escape" })

  vim.keymap.set("i", "<S-Tab>", function()
    if M.is_active(bufnr) then
      vim.cmd("stopinsert")
      M.promote_or_escape()
    else
      require("logseq.editing").insert_tab_outdent(bufnr)
    end
  end, { buffer = bufnr, silent = true, desc = "Logseq: outdent / zoom-escape (insert)" })

  -- ── move_up guard: zoom root cannot be displaced upward ──────────
  local move_up_key = km.move_up or "<A-Up>"
  vim.keymap.set("n", move_up_key, function()
    if not M.is_active(bufnr) then
      require("logseq.motions").move_up()
      return
    end
    local st     = _state[bufnr]
    local lnum   = vim.api.nvim_win_get_cursor(0)[1]
    local parsed = parser.parse_buf(bufnr)
    local block  = parser.block_at_line(parsed.blocks, lnum)
    if not block then return end
    -- Block cannot move above zoom_start (would leave the zoom range)
    if block.line_start <= st.zoom_start then return end
    local sibs = parser.siblings(block, parsed.blocks)
    local idx  = parser.sibling_index(block, sibs)
    if idx and idx > 1 and sibs[idx - 1].line_start < st.zoom_start then return end
    require("logseq.motions").move_up()
  end, { buffer = bufnr, silent = true, desc = "Logseq: move up (zoom-aware)" })

  -- ── move_down guard: zoom root cannot be displaced downward ───────
  local move_down_key = km.move_down or "<A-Down>"
  vim.keymap.set("n", move_down_key, function()
    if not M.is_active(bufnr) then
      require("logseq.motions").move_down()
      return
    end
    local st     = _state[bufnr]
    local lnum   = vim.api.nvim_win_get_cursor(0)[1]
    local parsed = parser.parse_buf(bufnr)
    local block  = parser.block_at_line(parsed.blocks, lnum)
    if not block then return end
    -- Do not allow moving the zoom root itself
    if block.line_start == st.zoom_start then return end
    -- Do not allow swapping with a block that extends past zoom_end
    local sibs = parser.siblings(block, parsed.blocks)
    local idx  = parser.sibling_index(block, sibs)
    if idx and idx < #sibs and sibs[idx + 1].line_end > st.zoom_end then return end
    require("logseq.motions").move_down()
  end, { buffer = bufnr, silent = true, desc = "Logseq: move down (zoom-aware)" })

  -- ── Clean up state when buffer is removed ─────────────────────────
  local grp = vim.api.nvim_create_augroup("LogseqZoom_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group    = grp,
    buffer   = bufnr,
    callback = function() _state[bufnr] = nil end,
  })
end

return M
