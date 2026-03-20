vim.g.mapleader = ","
vim.o.mouse = "a"  -- enable mouse/touch so winbar click targets work

-- Finn vault-sti: les fra lagret fil (satt av termux_setup.sh), ellers Windows-sti
local vault = nil
if vim.fn.has("win32") == 1 then
  vault = "C:/Users/kennetha/Documents/nvim/QAIA-Clean"
else
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