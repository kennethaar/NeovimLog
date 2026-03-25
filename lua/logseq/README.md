# logseq.nvim

Block-level outlining, folding, motions, backlinks, calendar sync, and link following for [Logseq](https://logseq.com/) vaults — operating directly on the same `.md` files without modifying them.

For full documentation see the root [README](../../README.md) or run `:help logseq` inside Neovim.

## Quick install (lazy.nvim)

```lua
{
  "kennethaar/neovimlog",
  ft = "markdown",
  opts = {
    vault_path = "~/your-logseq-vault",
  },
}
```

## Configuration

```lua
require("logseq").setup({
  vault_path         = nil,          -- REQUIRED
  journal_format     = "%Y_%m_%d",
  indent_size        = 2,
  fold_on_open       = false,
  enable_link_search = true,

  keymaps = {
    next_sibling     = "<leader>j",
    prev_sibling     = "<leader>k",
    first_child      = "<leader>J",
    parent           = "<leader>K",
    move_down        = "<A-Down>",
    move_up          = "<A-Up>",
    promote          = "<<",
    demote           = ">>",
    new_sibling      = "o",
    fold_toggle      = "za",
    follow_link      = "<CR>",
    toggle_backlinks = "<leader>b",
    todo_cycle       = "<C-t>",
    help             = "hh",
    search_pages     = "<C-k>",
  },
})
```

All keymaps are buffer-local and configurable at runtime via `:LogseqConfig`.

## Commands

| Command | Description |
|---------|-------------|
| `:LogseqToday` | Open today's journal |
| `:LogseqNewPage [name]` | Create or open a page |
| `:LogseqConfig` | Interactive keymap and button config |
| `:LogseqCalSync` | Sync calendar from ICS feeds |
| `:LogseqCalAdd` | Add an ICS calendar URL |
| `:LogseqCalEdit` | View or remove calendar URLs |
| `:LogseqCalRemind` | Set reminder lead time |
