vim.g.mapleader = ","

-- Finn riktig sti (Windows vs Termux)
local vault = ""
if vim.fn.has("win32") == 1 then
  vault = "C:/Users/kennetha/Documents/nvim/QAIA-Clean"
else
  vault = vim.fn.expand("~/storage/shared/Documents/Logseq/QAIA-Clean")
end

require("logseq").setup({
  vault_path = vault,
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