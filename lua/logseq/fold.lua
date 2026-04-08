--- logseq.nvim folding
---
--- Fold level mapping:
---   bullet at indent 0  → >1
---   bullet at indent 2  → >2
---   bullet at indent N  → >(N/2 + 1)
---   property/continuation → same level as owning block (via parser cache)
---   page property (col 0, no bullet) → 0
---   empty line → "="

local parser = require("logseq.parser")
local util   = require("logseq.util")

local M = {}

function M.foldexpr(lnum, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local line = vim.fn.getline(lnum)
  if line:match("^%s*$") then return "=" end

  local spaces = line:match("^(%s*)%- ")
  if spaces then return ">" .. (math.floor(#spaces / 2) + 1) end

  if line:match("^%S+::") then return 0 end

  -- Property / continuation: derive level from the owning block so that
  -- same-indent properties (pi == block.indent) get the correct fold level
  -- rather than one level too low. parse_buf is changedtick-cached, so fast.
  local ok, result = pcall(parser.parse_buf, bufnr)
  if ok then
    local block = parser.block_at_line(result.blocks, lnum)
    if block then
      return math.floor(block.indent / 2) + 1
    end
  end

  -- Fallback for pre-block lines or parse errors
  local indent = line:match("^(%s+)")
  if indent then return math.floor(#indent / 2) + 1 end

  return "="
end

function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  local n    = vim.v.foldend - vim.v.foldstart
  return n > 0 and (line .. "  ⋯ " .. n .. " lines") or line
end

-- ── COLLAPSE:: true persistence ───────────────────────────────────────

--- Close folds for all blocks that carry `collapse:: true`.
--- Called once after buffer activation (vim.scheduled so folds are ready).
function M.apply_collapse_properties(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local ok, result = pcall(parser.parse_buf, bufnr)
  if not ok then return end

  for _, block in ipairs(parser.flatten(result.blocks)) do
    local v = util.prop_ci(block.properties, "collapse")
    if v and v:lower() == "true" and vim.fn.foldclosed(block.line_start) == -1 then
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd(block.line_start .. "foldclose")
      end)
    end
  end
end

--- Add or remove `collapse:: true` on the block that owns `lnum`.
---@param bufnr integer
---@param lnum integer  1-indexed fold-start line
---@param should_collapse boolean
function M.update_collapse_property(bufnr, lnum, should_collapse)
  local ok, result = pcall(parser.parse_buf, bufnr)
  if not ok then return end

  local block = parser.block_at_line(result.blocks, lnum)
  if not block then return end

  -- Locate an existing collapse:: line within the block's own range.
  local collapse_lnum = nil
  local blines = vim.api.nvim_buf_get_lines(bufnr, block.line_start - 1, block.line_end, false)
  for li, bl in ipairs(blines) do
    if bl:lower():match("^%s*collapse::%s*") then
      collapse_lnum = block.line_start - 1 + li   -- 1-indexed absolute line
      break
    end
  end

  if should_collapse and not collapse_lnum then
    local indent = string.rep(" ", block.indent + 2)
    vim.api.nvim_buf_set_lines(bufnr, block.line_start, block.line_start, false,
      { indent .. "collapse:: true" })
  elseif not should_collapse and collapse_lnum then
    vim.api.nvim_buf_set_lines(bufnr, collapse_lnum - 1, collapse_lnum, false, {})
  end
end

function M.setup_buf(bufnr)
  vim.opt_local.foldmethod = "expr"
  vim.opt_local.foldexpr   = string.format("v:lua.require('logseq.fold').foldexpr(v:lnum,%d)", bufnr)
  vim.opt_local.foldtext   = "v:lua.require('logseq.fold').foldtext()"
  vim.opt_local.fillchars:append("fold: ")

  local config = require("logseq.config").current
  if not config.fold_on_open then
    vim.opt_local.foldlevel = 99
  end

  -- Wrap fold_toggle to persist COLLAPSE:: alongside the visual fold state.
  local km = config.keymaps or {}
  if km.fold_toggle then
    vim.keymap.set("n", km.fold_toggle, function()
      local lnum      = vim.fn.line(".")
      local was_closed = vim.fn.foldclosed(lnum) ~= -1
      vim.cmd("normal! za")
      local is_closed  = vim.fn.foldclosed(lnum) ~= -1
      if was_closed ~= is_closed then
        M.update_collapse_property(bufnr, lnum, is_closed)
      end
    end, { buffer = bufnr, silent = true, desc = "Logseq: toggle fold" })
  end

  -- Anti-flicker: suspend expression folding while typing.
  local group = vim.api.nvim_create_augroup("LogseqFoldFix_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group, buffer = bufnr,
    callback = function() vim.opt_local.foldmethod = "manual" end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group, buffer = bufnr,
    callback = function() vim.opt_local.foldmethod = "expr" end,
  })

  vim.schedule(function() M.apply_collapse_properties(bufnr) end)
end

return M
