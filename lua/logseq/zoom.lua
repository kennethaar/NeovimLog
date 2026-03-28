--- logseq.nvim zoom
--- Zoom into a block subtree using manual folds.
--- Everything outside the subtree is hidden behind ↑ … / ↓ … fold markers.
--- Outdenting a block that would become a sibling of the zoom root instead
--- moves it just after the subtree in the real document (escape behaviour).

local parser = require("logseq.parser")
local M = {}

---@class ZoomState
---@field zoom_start       integer  1-indexed first line of the zoom subtree
---@field zoom_end         integer  1-indexed last line of the zoom subtree
---@field zoom_root_indent integer  indent level of the zoom-root block
---@field breadcrumb       string   display string for winbar
---@field orig_foldmethod  string   foldmethod to restore on exit
---@field orig_foldtext    string   foldtext to restore on exit
local _state = {} -- bufnr → ZoomState

-- ── Helpers ──────────────────────────────────────────────────────────

local function indent_size()
  return require("logseq.config").current.indent_size or 2
end

local function build_breadcrumb(block, bufnr)
  local parts = {}
  local b = block
  while b do
    local c = b.content:gsub("^%u+%s+", ""):gsub("%s*$", "")
    if #c > 25 then c = c:sub(1, 23) .. "…" end
    table.insert(parts, 1, c)
    b = b.parent
  end
  local page = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r")
  if #page > 20 then page = page:sub(1, 18) .. "…" end
  table.insert(parts, 1, page)
  return table.concat(parts, " › ")
end

--- Rebuild the above/below manual folds.
--- Only call this from keymap handlers (current window must show bufnr).
local function apply_folds(bufnr, st)
  local total = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.cmd, "normal! zE")
  if st.zoom_start > 1 then
    pcall(vim.cmd, "1," .. (st.zoom_start - 1) .. "fold")
  end
  if st.zoom_end < total then
    pcall(vim.cmd, (st.zoom_end + 1) .. "," .. total .. "fold")
  end
  pcall(vim.cmd, "normal! zM")
end

-- ── Public API ────────────────────────────────────────────────────────

function M.is_active(bufnr)
  return _state[bufnr] ~= nil
end

function M.breadcrumb(bufnr)
  local st = _state[bufnr]
  return st and st.breadcrumb or nil
end

--- Called by foldtext option; must work during fold evaluation.
function M.foldtext()
  local bufnr = vim.api.nvim_get_current_buf()
  local st    = _state[bufnr]
  if not st then
    local ok, fold = pcall(require, "logseq.fold")
    return ok and fold.foldtext() or vim.fn.getline(vim.v.foldstart)
  end
  return vim.v.foldstart < st.zoom_start and "  ↑ …" or "  ↓ …"
end

function M.enter()
  local bufnr  = vim.api.nvim_get_current_buf()
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

  _state[bufnr] = {
    zoom_start       = block.line_start,
    zoom_end         = block.line_end,
    zoom_root_indent = block.indent,
    breadcrumb       = build_breadcrumb(block, bufnr),
    orig_foldmethod  = vim.wo.foldmethod,
    orig_foldtext    = vim.wo.foldtext,
  }

  vim.wo.foldmethod = "manual"
  vim.wo.foldtext   = "v:lua.require('logseq.zoom').foldtext()"
  apply_folds(bufnr, _state[bufnr])
  vim.api.nvim_win_set_cursor(0, { _state[bufnr].zoom_start, 0 })
  vim.cmd("redrawstatus")
end

function M.exit()
  local bufnr = vim.api.nvim_get_current_buf()
  local st    = _state[bufnr]
  if not st then return end

  -- Remove folds BEFORE clearing state so foldtext() stays coherent during zE.
  pcall(vim.cmd, "normal! zE")
  _state[bufnr] = nil

  vim.wo.foldmethod = st.orig_foldmethod ~= "" and st.orig_foldmethod or "expr"
  vim.wo.foldtext   = st.orig_foldtext   ~= "" and st.orig_foldtext
    or "v:lua.require('logseq.fold').foldtext()"
  vim.cmd("redrawstatus")
end

--- Promote the block, or escape it from the zoom if it sits at the
--- innermost level (one indent_size inside the zoom root).
--- Escaping moves the block to just after the zoom subtree in the real
--- document; it lands inside the below-fold and disappears from view.
function M.promote_or_escape()
  local bufnr   = vim.api.nvim_get_current_buf()
  local st      = _state[bufnr]
  local motions = require("logseq.motions")

  if not st then
    motions.promote()
    return
  end

  local lnum   = vim.api.nvim_win_get_cursor(0)[1]
  local parsed = parser.parse_buf(bufnr)
  local block  = parser.block_at_line(parsed.blocks, lnum)
  local sz     = indent_size()

  if not block or block.indent - sz ~= st.zoom_root_indent then
    motions.promote()
    return
  end

  -- Escape path ─────────────────────────────────────────────────────
  local b_start   = block.line_start
  local b_end     = block.line_end
  local b_count   = b_end - b_start + 1
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local escaped = {}
  for i = b_start, b_end do
    local line = all_lines[i]
    local ws   = #(line:match("^(%s*)") or "")
    escaped[#escaped + 1] = line:sub(math.min(sz, ws) + 1)
  end

  vim.api.nvim_buf_set_lines(bufnr, b_start - 1, b_end, false, {})
  st.zoom_end = st.zoom_end - b_count
  vim.api.nvim_buf_set_lines(bufnr, st.zoom_end, st.zoom_end, false, escaped)
  apply_folds(bufnr, st)

  local new_lnum = math.max(st.zoom_start, math.min(b_start, st.zoom_end))
  vim.api.nvim_win_set_cursor(0, { new_lnum, 0 })
end

-- ── Buffer Setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local km = require("logseq.config").current.keymaps

  -- ── Zoom toggle ───────────────────────────────────────────────────
  vim.keymap.set("n", km.zoom_toggle or "<leader>z", function()
    if M.is_active(bufnr) then M.exit() else M.enter() end
  end, { buffer = bufnr, silent = true, desc = "Logseq: zoom into block" })

  -- ── Promote overrides (share one handler for all bindings) ────────
  local function do_promote()
    if M.is_active(bufnr) then M.promote_or_escape()
    else require("logseq.motions").promote() end
  end
  vim.keymap.set("n", km.promote or "<<", do_promote,
    { buffer = bufnr, silent = true, desc = "Logseq: promote / zoom-escape" })
  vim.keymap.set("n", "<S-Tab>", do_promote,
    { buffer = bufnr, silent = true, desc = "Logseq: outdent / zoom-escape" })
  vim.keymap.set("i", "<S-Tab>", function()
    if M.is_active(bufnr) then
      vim.cmd("stopinsert")
      M.promote_or_escape()
    else
      require("logseq.editing").insert_tab_outdent(bufnr)
    end
  end, { buffer = bufnr, silent = true, desc = "Logseq: outdent / zoom-escape (insert)" })

  -- ── Move guards (shared helper eliminates duplication) ───────────
  local function guarded_move(direction)
    if not M.is_active(bufnr) then
      require("logseq.motions")["move_" .. direction]()
      return
    end
    local st     = _state[bufnr]
    local lnum   = vim.api.nvim_win_get_cursor(0)[1]
    local parsed = parser.parse_buf(bufnr)
    local block  = parser.block_at_line(parsed.blocks, lnum)
    if not block then return end

    local sibs = parser.siblings(block, parsed.blocks)
    local idx  = parser.sibling_index(block, sibs)

    if direction == "up" then
      if block.line_start <= st.zoom_start then return end
      if idx and idx > 1 and sibs[idx - 1].line_start < st.zoom_start then return end
    else
      if block.line_start == st.zoom_start then return end
      if idx and idx < #sibs and sibs[idx + 1].line_end > st.zoom_end then return end
    end

    require("logseq.motions")["move_" .. direction]()
  end

  vim.keymap.set("n", km.move_up   or "<A-Up>",   function() guarded_move("up")   end,
    { buffer = bufnr, silent = true, desc = "Logseq: move up (zoom-aware)" })
  vim.keymap.set("n", km.move_down or "<A-Down>", function() guarded_move("down") end,
    { buffer = bufnr, silent = true, desc = "Logseq: move down (zoom-aware)" })

  -- ── Clean up on buffer removal ────────────────────────────────────
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group    = vim.api.nvim_create_augroup("LogseqZoom_" .. bufnr, { clear = true }),
    buffer   = bufnr,
    callback = function() _state[bufnr] = nil end,
  })
end

return M
