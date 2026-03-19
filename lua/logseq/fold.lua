--- logseq.nvim folding
--- Per-line foldexpr using pattern matching. Does NOT parse the full tree.
---
--- Fold level mapping:
---   bullet at indent 0  → >1 (starts fold level 1)
---   bullet at indent 2  → >2 (starts fold level 2)
---   bullet at indent N  → >(N/2 + 1)
---   property/continuation → same level as parent (indent / 2)
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
  local folded_count = vim.v.foldend - vim.v.foldstart
  if folded_count > 0 then
    return line .. "  ⋯ " .. folded_count .. " lines"
  end
  return line
end

function M.setup_buf(bufnr)
  -- Default setup
  vim.opt_local.foldmethod = "expr"
  vim.opt_local.foldexpr = "v:lua.require('logseq.fold').foldexpr(v:lnum)"
  vim.opt_local.foldtext = "v:lua.require('logseq.fold').foldtext()"
  vim.opt_local.fillchars:append("fold: ")

  local config = require("logseq.config").current
  if not config.fold_on_open then
    vim.opt_local.foldlevel = 99
  end

  -- NEW: The Anti-Flicker Hack
  -- Suspend expression folding while typing!
  local group = vim.api.nvim_create_augroup("LogseqFoldFix_" .. bufnr, { clear = true })
  
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = bufnr,
    callback = function() vim.opt_local.foldmethod = "manual" end
  })
  
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = bufnr,
    callback = function() vim.opt_local.foldmethod = "expr" end
  })
end

return M