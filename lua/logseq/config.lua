local M = {}

M.defaults = {
  vault_path = nil, -- REQUIRED
  journal_format = "%Y_%m_%d",
  indent_size = 2,
  fold_on_open = false,

  keymaps = {
    next_sibling = "<leader>j",
    prev_sibling = "<leader>k",
    first_child  = "<leader>J",
    parent       = "<leader>K",
    move_down    = "<A-Down>",
    move_up      = "<A-Up>",
    promote      = "<S-Tab>",
    demote       = "<Tab>",
    new_sibling  = "o",
    fold_toggle  = "za",
    follow_link  = "<CR>",
  },
}

M.current = {}

function M.setup(opts)
  M.current = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})

  if not M.current.vault_path then
    vim.notify("[logseq.nvim] vault_path is required", vim.log.levels.ERROR)
    return false
  end

  M.current.vault_path = vim.fn.resolve(vim.fn.expand(M.current.vault_path)):gsub("\\", "/")

  if vim.fn.isdirectory(M.current.vault_path) == 0 then
    vim.notify("[logseq.nvim] vault not found: " .. M.current.vault_path, vim.log.levels.WARN)
  end

  return true
end

return M