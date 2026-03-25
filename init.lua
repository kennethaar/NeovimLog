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
-- 3. which-key (self-installing, independent of logseq plugin code)
-- ============================================================================
-- which-key shows a popup of available keybindings when you pause mid-chord.
-- We install it via Neovim's built-in package system (pack/*/start/) rather
-- than lazy.nvim, because lazy's setup() overrides laststatus and statusline
-- globally — exactly the UI state that logseq.nvim manages per-buffer.
local wk_path = vim.fn.stdpath("data") .. "/site/pack/plugins/start/which-key.nvim"
if not vim.uv.fs_stat(wk_path) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none", "--depth=1",
    "https://github.com/folke/which-key.nvim.git",
    wk_path,
  })
  -- On first clone, pack/*/start/ wasn't scanned yet this session,
  -- so add it to rtp manually. Subsequent startups auto-load it.
  vim.opt.rtp:append(wk_path)
end
pcall(function() require("which-key").setup({}) end)

-- ============================================================================
-- 4. Plugin Initialization
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
-- 5. Autocommands
-- ============================================================================

-- Create an augroup to clear existing autocmds on config reload (:source %)
local logseq_grp = vim.api.nvim_create_augroup("LogseqStartup", { clear = true })

-- Open today's journal and sync the calendar automatically when Neovim starts
-- with no file arguments — the normal "just open your notes" launch path.
vim.api.nvim_create_autocmd("VimEnter", {
  group = logseq_grp,
  callback = function()
    -- Only run if opening Neovim without specific file arguments
    if vim.fn.argc() ~= 0 then return end

    vim.cmd("LogseqToday")

    -- vim.schedule defers until the event loop is idle rather than using an
    -- arbitrary sleep, so the UI is never blocked and there are no race
    -- conditions against BufReadPost autocmds fired by LogseqToday.
    vim.schedule(function()
      local ok_cal, cal = pcall(require, "logseq.calendar")
      if ok_cal then
        cal.sync()
      else
        vim.notify("[logseq.nvim] calendar module not found — skipping sync.", vim.log.levels.WARN)
      end
    end)
  end,
})

