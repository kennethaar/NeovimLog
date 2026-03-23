vim.g.mapleader = ","
vim.o.mouse = "a"  -- enable mouse/touch so winbar click targets work

-- System clipboard (Windows / WSL / Wayland / X11 / Termux)
require("clipboard").setup()

vim.opt.wrap = true
vim.opt.linebreak = true
vim.opt.breakindent = true
vim.opt.breakindentopt = "shift:2"

-- Machine-specific overrides: create local.lua (gitignored) to override anything.
-- Example local.lua:
--   return { vault_path = "D:/Notes/MyVault" }
local local_ok, local_cfg = pcall(require, "local")
local overrides = local_ok and local_cfg or {}

-- Resolve vault path: local.lua wins, then the stored path file (written by setup scripts),
-- then nil (which triggers interactive setup inside the plugin).
local vault = overrides.vault_path
if not vault then
  local vault_file = vim.fn.stdpath("data") .. "/logseq_vault"
  local f = io.open(vault_file, "r")
  if f then
    vault = f:read("*l")
    f:close()
  end
end

require("logseq").setup({
  vault_path = vault,  -- nil triggers interactive setup in Neovim if file not found
})

-- Start Logseq og kalender automatisk når du åpner nvim
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    if vim.fn.argc() == 0 then
      vim.cmd("LogseqToday")

      -- Vent et halvt sekund så fila er klar, og kjør kalenderen fra logseq-mappa
      vim.defer_fn(function()
        local ok, cal = pcall(require, "logseq.calendar")
        if ok then
          cal.sync()
        else
          print("FEIL: Fant ikke lua/logseq/calendar.lua!")
        end
      end, 500)
    end
  end,
})
