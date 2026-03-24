-- ============================================================================
-- 1. General Settings
-- ============================================================================
vim.g.mapleader = ","
vim.opt.mouse = "a"

-- Note: Native Neovim can usually handle clipboard via `vim.opt.clipboard = "unnamedplus"`.
-- Wrapping your custom module in a pcall ensures Neovim doesn't break if it's missing.
local ok_clip, clipboard = pcall(require, "clipboard")
if ok_clip then clipboard.setup() end

-- Grouping UI options
vim.opt.wrap = true
vim.opt.linebreak = true
vim.opt.breakindent = true
vim.opt.breakindentopt = "shift:2"

-- ============================================================================
-- 2. Vault Path Resolution
-- ============================================================================
local vault_path = nil

-- Check local overrides first
local ok_local, local_cfg = pcall(require, "local")
if ok_local and type(local_cfg) == "table" then
  vault_path = local_cfg.vault_path
end

-- Fallback: Read stored path using native Neovim APIs
if not vault_path then
  local vault_file = vim.fn.stdpath("data") .. "/logseq_vault"
  if vim.fn.filereadable(vault_file) == 1 then
    -- readfile() is safer and more idiomatic in Neovim than standard io.open
    local lines = vim.fn.readfile(vault_file)
    if lines and #lines > 0 then
      vault_path = lines[1]
    end
  end
end

-- ============================================================================
-- 3. Plugin Initialization
-- ============================================================================
local ok_logseq, logseq = pcall(require, "logseq")
if ok_logseq then
  logseq.setup({
    vault_path = vault_path,
  })
else
  -- Warn gracefully instead of crashing the startup
  vim.notify("Logseq plugin not found or failed to load.", vim.log.levels.WARN)
end

-- ============================================================================
-- 4. Autocommands
-- ============================================================================
-- Create an augroup to clear existing autocmds on config reload (:source %)
local logseq_grp = vim.api.nvim_create_augroup("LogseqStartup", { clear = true })

-- Start Logseq og kalender automatisk når du åpner nvim
vim.api.nvim_create_autocmd("VimEnter", {
  group = logseq_grp,
  callback = function()
    -- Only run if opening Neovim without specific file arguments
    if vim.fn.argc() ~= 0 then return end

    vim.cmd("LogseqToday")

    -- Replace arbitrary 500ms wait with vim.schedule.
    -- This queues the function to run as soon as the Neovim event loop is idle, 
    -- ensuring the UI isn't blocked and avoiding race conditions.
    vim.schedule(function()
      local ok_cal, cal = pcall(require, "logseq.calendar")
      if ok_cal then
        cal.sync()
      else
        vim.notify("FEIL: Fant ikke lua/logseq/calendar.lua!", vim.log.levels.ERROR)
      end
    end)
  end,
})

