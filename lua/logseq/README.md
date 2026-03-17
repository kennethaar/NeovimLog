# logseq.nvim

Block-level outlining, folding, motions, and link following for [Logseq](https://logseq.com/) vaults in Neovim — operating directly on the same `.md` files without modification.

## Status

Phase 1–2–4: parser, folding, motions, link following.

## Install

### lazy.nvim (local development)

```lua
{
  dir = "~/dev/logseq.nvim",
  ft = "markdown",
  opts = {
    vault_path = "~/logseq-vault",
  },
}
```

## Configuration

All options with defaults:

```lua
require("logseq").setup({
  vault_path = nil,              -- REQUIRED: path to your Logseq vault
  journal_format = "%Y_%m_%d",  -- journal filename date format
  indent_size = 2,               -- Logseq standard
  fold_on_open = false,          -- start buffers folded?

  keymaps = {
    next_sibling = "]b",
    prev_sibling = "[b",
    parent       = "[B",
    first_child  = "]B",
    move_down    = "<A-j>",
    move_up      = "<A-k>",
    promote      = "<<",
    demote       = ">>",
    new_sibling  = "<CR>",
    fold_toggle  = "za",
    follow_link  = "gf",
  },
})
```

Keymaps are buffer-local — they only activate in `.md` files inside your vault.

`<<` and `>>` override Vim's built-in shift operators within vault buffers.

## Keymaps

| Key      | Action                            |
|----------|-----------------------------------|
| `]b`     | Next sibling block                |
| `[b`     | Previous sibling block            |
| `]B`     | First child block                 |
| `[B`     | Parent block                      |
| `<A-j>`  | Swap block (+ subtree) down       |
| `<A-k>`  | Swap block (+ subtree) up         |
| `>>`     | Demote subtree (+2 spaces)        |
| `<<`     | Promote subtree (−2 spaces)       |
| `<CR>`   | New sibling block below (normal)  |
| `za`     | Toggle fold                       |
| `gf`     | Follow link under cursor          |

## Commands

| Command             | Description                     |
|---------------------|---------------------------------|
| `:LogseqToday`      | Open today's journal            |
| `:LogseqNewPage`    | Create a new page               |
| `:LogseqFollowLink` | Follow link under cursor        |

## Link Following

| Syntax           | Resolves to                                          |
|------------------|------------------------------------------------------|
| `[[Page Name]]`  | `pages/Page Name.md`                                 |
| `[[NS/Child]]`   | `pages/NS___Child.md`                                |
| `((block-uuid))` | Greps vault for `id:: <uuid>`, jumps to that block   |
| `#tag`           | `pages/tag.md`                                       |

Falls back to normal `gf` when cursor is not on a link.

## File Safety

The plugin never modifies files unless you explicitly edit. It respects Logseq's 2-space indent, `id::` properties, flat namespace encoding, and never touches `logseq/`.

## Roadmap

- [ ] Vault indexer
- [ ] Path-ref inheritance (effective_refs)
- [ ] Linked References panel
- [ ] Query parser + executor
- [ ] Query result display
- [ ] Namespace browsing
