--- logseq.nvim external task API
--- Receives tasks from external tools (e.g. LogseqQuickAdd) via Neovim RPC.
--- Call from outside Neovim:
---   nvim --server \\.\pipe\nvim --remote-expr "luaeval(\"require('logseq.external').add_task('{...}')\")"

local config = require("logseq.config")

local M = {}

--- Add a task to today's journal buffer.
--- Accepts a JSON string with fields: text, status, context.
--- Returns "ok" on success, "err:message" on failure.
---@param opts_json string JSON-encoded table
---@return string
function M.add_task(opts_json)
  -- Parse input
  local ok, opts = pcall(vim.json.decode, opts_json)
  if not ok or type(opts) ~= "table" then
    return "err:invalid JSON input"
  end

  local text = opts.text or ""
  local status = opts.status or ""
  local context = opts.context or ""

  if text == "" then
    return "err:empty task text"
  end

  -- Check plugin is initialized
  local vault_path = config.current.vault_path
  if not vault_path or vault_path == "" then
    return "err:plugin not initialized (no vault_path)"
  end

  -- Build today's journal path (same logic as LogseqToday command in init.lua)
  local journal_format = config.current.journal_format or "%Y_%m_%d"
  local dir = vim.fs.joinpath(vault_path, "journals")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local filepath = vim.fs.joinpath(dir, os.date(journal_format) .. ".md")

  -- Find or load the journal buffer (without switching the user's window)
  local bufnr = vim.fn.bufnr(filepath)
  if bufnr == -1 then
    bufnr = vim.fn.bufadd(filepath)
    vim.fn.bufload(bufnr)
  end

  -- Build the block lines
  local lines = {}
  local first_line_parts = vim.split(text, "\n", { plain = true })
  local bullet = "- "
  if status ~= "" then
    bullet = bullet .. status .. " "
  end
  bullet = bullet .. (first_line_parts[1] or "")
  lines[#lines + 1] = bullet

  -- Context property line (indented under the bullet)
  if context ~= "" then
    lines[#lines + 1] = "  context:: [[" .. context .. "]]"
  end

  -- Remaining lines become sub-blocks
  for i = 2, #first_line_parts do
    local sub = vim.trim(first_line_parts[i])
    if sub ~= "" then
      lines[#lines + 1] = "  - " .. sub
    end
  end

  -- Append to buffer
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, lines)

  -- Mark modified so autosave picks it up
  vim.bo[bufnr].modified = true

  -- Ensure autosave is set up if buffer wasn't activated by the plugin yet
  if not vim.b[bufnr].logseq_active then
    pcall(function()
      require("logseq.autosave").setup_buf(bufnr)
    end)
  end

  return "ok"
end

--- Add a task by reading JSON from a temp file written by LogseqQuickAdd.
--- This avoids command-line escaping issues with nested quotes.
--- The temp file is deleted after reading.
---@return string
function M.add_task_from_file()
  local temp = os.getenv("TEMP") or os.getenv("TMP") or ""
  if temp == "" then
    return "err:TEMP environment variable not set"
  end
  local filepath = temp .. "\\logseq_quickadd_task.json"
  local f = io.open(filepath, "r")
  if not f then
    return "err:task file not found at " .. filepath
  end
  local json_str = f:read("*a")
  f:close()
  os.remove(filepath)
  return M.add_task(json_str)
end

return M
