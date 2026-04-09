--- logseq.nvim block zoom
--- Zoom into a block: fold everything outside the block's subtree.
--- Toggle with the zoom_block keymap (default <leader>Z).

local parser = require("logseq.parser")
local M = {}

-- Module-level state: keyed by bufnr
-- { lnum = N, content_fp = "...", block = <ref> }
local _state = {}

-- ── Helpers ───────────────────────────────────────────────────────────

--- Find the block that was originally at `lnum`, using content as a secondary
--- fingerprint so we survive line-number shifts from edits before the block.
local function find_current_block(bufnr, lnum, content_fp)
  local ok, result = pcall(parser.parse_buf, bufnr)
  if not ok then return nil end

  -- Fast path: block still at stored lnum
  local block = parser.block_at_line(result.blocks, lnum)
  if block and block.line_start == lnum then
    return block
  end

  -- Fallback: scan flat list for matching content fingerprint
  if content_fp and content_fp ~= "" then
    for _, b in ipairs(parser.flatten(result.blocks)) do
      if vim.trim(b.content):sub(1, 40) == content_fp then
        return b
      end
    end
  end
  return nil
end

--- Update vim.b zoom bounds from current parse (called on InsertLeave / TextChanged).
local function refresh_bounds(bufnr)
  local st = _state[bufnr]
  if not st then return end
  local block = find_current_block(bufnr, st.lnum, st.content_fp)
  if not block then return end
  st.lnum  = block.line_start
  st.block = block
  vim.b[bufnr].logseq_zoom_lnum = block.line_start
  vim.b[bufnr].logseq_zoom_end  = block.line_end
end

-- ── Public API ────────────────────────────────────────────────────────

function M.is_zoomed(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return _state[bufnr] ~= nil
end

--- Return the currently-zoomed block reference.
function M.get_zoom_block(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = _state[bufnr]
  return st and st.block or nil
end

function M.enter(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local ok, result = pcall(parser.parse_buf, bufnr)
  if not ok then return end
  local block = parser.block_at_line(result.blocks, lnum)
  if not block then
    vim.notify("[logseq] No block under cursor to zoom into.", vim.log.levels.WARN)
    return
  end

  local content_fp = vim.trim(block.content):sub(1, 40)
  _state[bufnr] = { lnum = block.line_start, content_fp = content_fp, block = block }

  vim.b[bufnr].logseq_zoom_lnum = block.line_start
  vim.b[bufnr].logseq_zoom_end  = block.line_end

  -- Lower foldlevel: level-99 folds (outside lines) close, levels 1-98 stay open
  vim.wo.foldlevel = 98
  -- Re-evaluate all foldexpr lines so outside lines get level-99 folds (closed)
  vim.cmd("normal! zx")
  -- Ensure everything inside the block range is expanded
  vim.cmd("silent! " .. block.line_start .. "," .. block.line_end .. "foldopen!")
  vim.api.nvim_win_set_cursor(0, { block.line_start, 0 })
  vim.cmd("redrawstatus")
end

function M.exit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local saved_lnum = vim.b[bufnr].logseq_zoom_lnum or vim.api.nvim_win_get_cursor(0)[1]
  _state[bufnr] = nil
  vim.b[bufnr].logseq_zoom_lnum = nil
  vim.b[bufnr].logseq_zoom_end  = nil
  -- Restore full foldlevel
  vim.wo.foldlevel = 99
  -- Re-evaluate folds (outside lines return normal levels again)
  vim.cmd("normal! zx")
  -- Re-apply collapse:: properties that were present before zoom
  pcall(function() require("logseq.fold").apply_collapse_properties(bufnr) end)
  vim.api.nvim_win_set_cursor(0, { saved_lnum, 0 })
  vim.cmd("redrawstatus")
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  if M.is_zoomed(bufnr) then
    M.exit(bufnr)
  else
    M.enter(bufnr)
  end
end

function M.setup_buf(bufnr)
  local km = require("logseq.config").current.keymaps
  local key = km.zoom_block or "<leader>Z"

  vim.keymap.set("n", key, M.toggle,
    { buffer = bufnr, silent = true, desc = "Logseq: toggle block zoom" })

  -- Keep logseq_zoom_end current so foldexpr always has the accurate line_end
  -- after the user adds children to the zoomed block.
  local grp = vim.api.nvim_create_augroup("LogseqZoom_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
    group = grp,
    buffer = bufnr,
    callback = function()
      if not vim.b[bufnr].logseq_zoom_lnum then return end
      vim.schedule(function() refresh_bounds(bufnr) end)
    end,
  })
end

return M
