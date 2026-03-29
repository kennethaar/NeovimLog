--- logseq.nvim folding
--- Per-line foldexpr using pattern matching. Does NOT parse the full tree.
---
--- Fold level mapping:
---   bullet at indent 0  → >1
---   bullet at indent 2  → >2
---   bullet at indent N  → >(N/2 + 1)
---   property/continuation → same level as parent
---   page property (col 0, no bullet) → 0
---   empty line → "="

local M = {}

function M.foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  if line:match("^%s*$") then return "=" end

  local spaces = line:match("^(%s*)%- ")
  if spaces then return ">" .. (math.floor(#spaces / 2) + 1) end

  if line:match("^%S+::") then return 0 end

  local indent = line:match("^(%s+)")
  if indent then return math.max(1, math.floor(#indent / 2)) end

  return "="
end

function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  local n    = vim.v.foldend - vim.v.foldstart
  return n > 0 and (line .. "  ⋯ " .. n .. " lines") or line
end

-- ── COLLAPSE:: true persistence ───────────────────────────────────────

--- Case-insensitive property lookup in a block's properties table.
local function get_prop_ci(props, key_lower)
  for k, v in pairs(props) do
    if k:lower() == key_lower then return v end
  end
  return nil
end

--- Close folds for all blocks that carry `collapse:: true`.
--- Called once after buffer activation (vim.scheduled so folds are ready).
function M.apply_collapse_properties(bufnr)
  local ok, parser = pcall(require, "logseq.parser")
  if not ok then return end
  local ok2, result = pcall(parser.parse_buf, bufnr)
  if not ok2 then return end

  local flat = parser.flatten(result.blocks)
  for _, block in ipairs(flat) do
    local v = get_prop_ci(block.properties, "collapse")
    if v and v:lower() == "true" then
      local lnum = block.line_start
      if vim.fn.foldclosed(lnum) == -1 then
        -- Only close if the fold exists (i.e. block has children)
        pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd(lnum .. "foldclose")
        end)
      end
    end
  end
end

--- Add or remove `collapse:: true` property for the block that owns `lnum`.
---@param bufnr integer
---@param lnum integer  1-indexed line number (typically the fold start)
---@param should_collapse boolean
function M.update_collapse_property(bufnr, lnum, should_collapse)
  local ok, parser = pcall(require, "logseq.parser")
  if not ok then return end
  local ok2, result = pcall(parser.parse_buf, bufnr)
  if not ok2 then return end

  local block = parser.block_at_line(result.blocks, lnum)
  if not block then return end

  -- Find existing collapse property line (if any) within the block's range.
  local collapse_lnum = nil
  local blines = vim.api.nvim_buf_get_lines(bufnr, block.line_start - 1, block.line_end, false)
  for li, bl in ipairs(blines) do
    if bl:lower():match("^%s*collapse::%s*") then
      collapse_lnum = block.line_start - 1 + li  -- 1-indexed
      break
    end
  end

  if should_collapse and not collapse_lnum then
    -- Insert `  collapse:: true` after the block's bullet line.
    local indent = string.rep(" ", block.indent + 2)
    vim.api.nvim_buf_set_lines(bufnr, block.line_start, block.line_start, false,
      { indent .. "collapse:: true" })
  elseif not should_collapse and collapse_lnum then
    -- Remove the collapse:: line entirely.
    vim.api.nvim_buf_set_lines(bufnr, collapse_lnum - 1, collapse_lnum, false, {})
  end
end

function M.setup_buf(bufnr)
  vim.opt_local.foldmethod = "expr"
  vim.opt_local.foldexpr = "v:lua.require('logseq.fold').foldexpr(v:lnum)"
  vim.opt_local.foldtext = "v:lua.require('logseq.fold').foldtext()"
  vim.opt_local.fillchars:append("fold: ")

  local config = require("logseq.config").current
  if not config.fold_on_open then
    vim.opt_local.foldlevel = 99
  end

  -- Bind fold_toggle keymap — wraps `za` to also persist COLLAPSE:: property.
  local km = config.keymaps or {}
  if km.fold_toggle then
    vim.keymap.set("n", km.fold_toggle, function()
      local fold_lnum    = vim.fn.line(".")
      local was_closed   = vim.fn.foldclosed(fold_lnum) ~= -1
      vim.cmd("normal! za")
      local is_closed    = vim.fn.foldclosed(fold_lnum) ~= -1
      if was_closed ~= is_closed then
        M.update_collapse_property(bufnr, fold_lnum, is_closed)
      end
    end, {
      buffer = bufnr,
      silent = true,
      desc = "Logseq: toggle fold",
    })
  end

  -- Anti-Flicker: suspend expression folding while typing
  local group = vim.api.nvim_create_augroup("LogseqFoldFix_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = bufnr,
    callback = function() vim.opt_local.foldmethod = "manual" end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = bufnr,
    callback = function()
      vim.opt_local.foldmethod = "expr"
    end,
  })

  -- Apply persisted COLLAPSE:: properties after the buffer and folds are ready.
  vim.schedule(function() M.apply_collapse_properties(bufnr) end)
end

return M
