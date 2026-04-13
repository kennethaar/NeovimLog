-- ============================================================================
-- 1. General Settings
-- ============================================================================
vim.g.mapleader = ","
vim.opt.mouse = "a"

-- Note: Native Neovim can usually handle clipboard via `vim.opt.clipboard = "unnamedplus"`.
local ok_clip, clipboard = pcall(require, "clipboard")
if ok_clip then
  clipboard.setup()
  clipboard.setup_shortcuts()
end

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
    local lines = vim.fn.readfile(vault_file)
    if lines and #lines > 0 then
      vault_path = lines[1]
    end
  end
end

-- ============================================================================
-- 3. which-key 
-- ============================================================================
local wk_path = vim.fn.stdpath("data") .. "/site/pack/plugins/start/which-key.nvim"
if not vim.uv.fs_stat(wk_path) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none", "--depth=1",
    "https://github.com/folke/which-key.nvim.git",
    wk_path,
  })
  vim.opt.rtp:append(wk_path)
end
pcall(function() require("which-key").setup({}) end)

-- ============================================================================
-- 3.5 markdown-preview.nvim (Browser-based Rendering)
-- ============================================================================
local mkdp_path = vim.fn.stdpath("data") .. "/site/pack/plugins/start/markdown-preview.nvim"
if not vim.uv.fs_stat(mkdp_path) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none", "--depth=1",
    "https://github.com/iamcco/markdown-preview.nvim.git",
    mkdp_path,
  })
  vim.opt.rtp:append(mkdp_path)
  
  -- Notify you on first install to run the build command
  vim.schedule(function()
    vim.notify("Markdown Preview downloaded! Please run :call mkdp#util#install()", vim.log.levels.INFO)
  end)
end

-- Do not auto-close the preview window when switching buffers
vim.g.mkdp_auto_close = 0 

-- Map <leader>mp to toggle the preview window
vim.keymap.set("n", "<leader>mp", "<cmd>MarkdownPreviewToggle<CR>", { desc = "Toggle Markdown Preview" })

-- ============================================================================
-- 4. Plugin Initialization (Logseq)
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
local logseq_grp = vim.api.nvim_create_augroup("LogseqStartup", { clear = true })

vim.api.nvim_create_autocmd("VimEnter", {
  group = logseq_grp,
  callback = function()
    -- Only run if opening Neovim without specific file arguments
    if vim.fn.argc() ~= 0 then return end

    vim.cmd("LogseqToday")

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