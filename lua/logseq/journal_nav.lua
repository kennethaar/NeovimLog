--- logseq.nvim journal navigation
--- Open today / tomorrow / yesterday journal pages.

local M = {}

local function open_journal_by_offset(offset_days)
  local config = require("logseq.config")
  local dir = config.current.vault_path .. "/journals"
  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
  local name = os.date(config.current.journal_format, os.time() + offset_days * 86400)
  local filepath = dir .. "/" .. name .. ".md"
  if vim.bo.modified then vim.cmd("write") end
  vim.cmd("edit " .. vim.fn.fnameescape(filepath))
end

function M.open_today()     open_journal_by_offset(0)  end
function M.open_tomorrow()  open_journal_by_offset(1)  end
function M.open_yesterday() open_journal_by_offset(-1) end

return M
