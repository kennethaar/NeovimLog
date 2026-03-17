vim.g.mapleader = ","

require("logseq").setup({
  vault_path = "C:/Users/kennetha/Documents/nvim/QAIA-Clean",
})

vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    if vim.fn.argc() == 0 then
      vim.cmd("LogseqToday")
    end
  end,
})