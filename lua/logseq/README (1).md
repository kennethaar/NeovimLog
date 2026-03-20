# logseq.nvim

Block-level outlining, folding, motions, and link following for [Logseq](https://logseq.com/) vaults in Neovim — operating directly on the same `.md` files without modification.

## Status

Parser, folding, motions, link following, backlinks, queries, calendar sync, templates.

## Install

### lazy.nvim

```lua
{
  dir = "~/dev/logseq.nvim",
  ft = "markdown",
  opts = {
    vault_path = "~/logseq-vault",
  },
}
```

### Prerequisites

- Neovim 0.9+
- Python 3 (required only for Calendar Sync)

## Configuration

All options with defaults:

```lua
require("logseq").setup({
  vault_path = nil,              -- REQUIRED: path to your Logseq vault
  journal_format = "%Y_%m_%d",  -- journal filename date format
  indent_size = 2,               -- Logseq standard (used by all indent operations)
  fold_on_open = false,          -- start buffers folded?
  enable_link_search = true,     -- fuzzy page search on [[

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
  },
})
```

Keymaps are buffer-local — they only activate in `.md` files inside your vault.

`<<` and `>>` override Vim's built-in shift operators within vault buffers.

## Keymaps

### Normal Mode

| Key            | Action                            |
|----------------|-----------------------------------|
| `<leader>j`    | Next sibling block                |
| `<leader>k`    | Previous sibling block            |
| `<leader>J`    | First child block                 |
| `<leader>K`    | Parent block                      |
| `<A-Down>`     | Swap block (+ subtree) down       |
| `<A-Up>`       | Swap block (+ subtree) up         |
| `>>`           | Demote subtree (+indent)          |
| `<<`           | Promote subtree (−indent)         |
| `o`            | New sibling block below           |
| `O`            | New sibling block above           |
| `za`           | Toggle fold                       |
| `<CR>`         | Follow link under cursor          |
| `<leader>b`    | Toggle backlinks panel            |
| `<leader>q`    | Toggle queries panel              |
| `<leader>t`    | Apply template                    |
| `<C-t>`        | Cycle TODO state                  |
| `Tab`          | Indent line (>>)                  |
| `S-Tab`        | Outdent line (<<)                 |
| `hh`           | Show help                         |

### Insert Mode

| Key            | Action                            |
|----------------|-----------------------------------|
| `<CR>`         | Smart Enter: new sibling bullet   |
| `<S-CR>`       | New property/continuation line    |
| `<Tab>`        | Indent block (parser-aware)       |
| `<S-Tab>`      | Outdent block (parser-aware)      |
| `<C-t>`        | Cycle TODO state                  |
| `[[`           | Fuzzy page search completion      |

### Visual Mode

| Key            | Action                            |
|----------------|-----------------------------------|
| `<CR>`         | Wrap selection in [[link]]        |

## Commands

| Command             | Description                          |
|---------------------|--------------------------------------|
| `:LogseqToday`      | Open today's journal                 |
| `:LogseqNewPage`    | Create a new page (handles encoding) |
| `:Calsync`          | Force calendar sync                  |
| `:Caladd`           | Add calendar ICS URLs interactively  |
| `:Calremind`        | Set reminder lead time               |

## Link Following

| Syntax           | Resolves to                                          |
|------------------|------------------------------------------------------|
| `[[Page Name]]`  | `pages/Page Name.md`                                 |
| `[[NS/Child]]`   | `pages/NS___Child.md`                                |
| `((block-uuid))` | Greps vault for `id:: <uuid>`, jumps to that block   |
| `#tag`           | `pages/tag.md`                                       |

Falls back to normal behavior when cursor is not on a link.

## File Safety

The plugin never modifies files unless you explicitly edit. It respects Logseq's 2-space indent, `id::` properties, flat namespace encoding, and never touches `logseq/`.

## Architecture

The plugin is organized into focused modules:

- `parser.lua` — Pure Lua block tree parser with buffer-level caching
- `motions.lua` — Block navigation and movement
- `editing.lua` — Smart Enter, property insertion, TODO cycling
- `fold.lua` — Expression-based folding with anti-flicker
- `links.lua` — Link following and visual link wrapping
- `backlinks.lua` — Linked References panel
- `queries.lua` — Task queries with inline editing
- `indexer.lua` — Async vault scanner for backlink discovery
- `page_search.lua` — Fuzzy page completion on `[[`
- `ui.lua` — Winbar, statusline, syntax concealment
- `calendar.lua` — ICS calendar sync
- `reminders.lua` — Meeting countdown and popup reminders
- `templates.lua` — Namespace-based template system
- `autosave.lua` — Debounced autosave
- `config.lua` — Configuration and vault-local persistence
- `util.lua` — Shared utilities (path normalization, filename encoding)
