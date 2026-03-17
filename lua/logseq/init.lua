--- logseq.nvim — Logseq vault editing in Neovim
--- Phase 1-2-4: block parsing, folding, motions, link following.

local config = require("logseq.config")

local M = {}

--- Normalize a path for comparison: resolve, expand, forward slashes, lowercase on Windows.
---@param p string
---@return string
local function normalize(p)
  local resolved = vim.fn.resolve(vim.fn.expand(p)):gsub("\\", "/")
  -- Windows is case-insensitive
  if vim.fn.has("win32") == 1 then
    resolved = resolved:lower()
  end
  return resolved
end

--- Check if a filepath is inside the configured vault.
---@param bufpath string
---@return boolean
local function is_vault_file(bufpath)
  local vault = config.current.vault_norm
  if not vault or vault == "" then return false end
  return normalize(bufpath):sub(1, #vault) == vault
end

--- Activate logseq.nvim on a buffer (folding, motions, links).
---@param bufnr integer
local function activate(bufnr)
  if vim.b[bufnr].logseq_active then return end
  vim.b[bufnr].logseq_active = true

  require("logseq.fold").setup_buf()
  require("logseq.motions").setup_buf()
  require("logseq.links").setup_buf()

  -- Enforce Logseq's 2-space indent
  vim.opt_local.shiftwidth = 2
  vim.opt_local.tabstop = 2
  vim.opt_local.expandtab = true
  vim.opt_local.softtabstop = 2
end

--- Activate the current buffer if it's a vault file.
local function try_activate_current()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("%.md$") and is_vault_file(name) then
    activate(buf)
  end
end

--- Main setup. Call from lazy.nvim opts/config.
---@param opts table
function M.setup(opts)
  if not config.setup(opts) then return end

  -- Store normalized vault path for comparison
  config.current.vault_norm = normalize(config.current.vault_path)

  local group = vim.api.nvim_create_augroup("logseq_nvim", { clear = true })

  -- Activate on any .md file inside the vault
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if is_vault_file(vim.api.nvim_buf_get_name(ev.buf)) then
        activate(ev.buf)
      end
    end,
  })

  -- If the current buffer is already a vault file, activate now
  try_activate_current()

  -- ── Commands ──────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("LogseqToday", function()
    local vault = config.current.vault_path
    local dir = vault .. "/journals"
    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end

    local filename = os.date(config.current.journal_format) .. ".md"
    local filepath = dir .. "/" .. filename

    -- Skip if already viewing this file
    if normalize(vim.api.nvim_buf_get_name(0)) == normalize(filepath) then
      return
    end

    -- Save current buffer if modified, then open
    if vim.bo.modified then
      vim.cmd("write")
    end
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))

    -- Defer activation to ensure buffer is fully set up
    vim.defer_fn(function()
      activate(vim.api.nvim_get_current_buf())
    end, 10)
  end, { desc = "Open today's journal" })

  vim.api.nvim_create_user_command("LogseqNewPage", function(cmd)
    local name = cmd.args
    if name == "" then
      name = vim.fn.input("Page name: ")
    end
    if name == "" then return end

    local vault = config.current.vault_path
    local dir = vault .. "/pages"
    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end

    local filename = require("logseq.links").page_to_filename(name)
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. filename))
    vim.defer_fn(function()
      activate(vim.api.nvim_get_current_buf())
    end, 10)
  end, { nargs = "?", desc = "Create a new Logseq page" })

  vim.api.nvim_create_user_command("LogseqFollowLink", function()
    require("logseq.links").follow()
  end, { desc = "Follow link under cursor" })
end

return M