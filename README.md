# NeovimLog

**Your Logseq vault, at Neovim speed.**

[Logseq](https://logseq.com/) is a powerful knowledge graph built on Markdown. But its Electron desktop app is slow to start, heavy on memory, and far from the terminal. NeovimLog gives you everything Logseq's outliner is built on — block navigation, backlinks, calendar sync, wikilinks, folding, and TODO states — inside Neovim, opening instantly, reading the exact same `.md` files your Logseq app writes.

**Why Neovim?** Because it starts in milliseconds, runs over SSH, composes with every tool in your terminal, and has a plugin ecosystem built by people who value correctness and speed. NeovimLog stands on those foundations.

**Why open source?** Because your notes and the tool you use to write them should both belong to you. NeovimLog is MIT-licensed.

---

## Features

- Block-level navigation — next/prev sibling, parent, first child
- Smart block editing — split, move, indent/outdent with full subtree
- Wikilinks `[[Page Name]]`, block references `((uuid))`, `#tags` — followable with `<CR>`
- Backlinks panel — async vault indexing, never writes to disk
- Fuzzy `[[` completion over all pages and journals
- Calendar sync from ICS feeds (Google, Outlook, iCloud)
- Meeting reminders shown in the winbar
- Namespace template system with interactive placeholders
- Clickable winbar and statusline (rename, sync, backlinks, navigation)
- Full concealment of `[[`, `]]`, `id::` and namespace prefixes
- TODO cycling: `TODO` → `DOING` → `DONE` → `CANCELLED` → `WAITING`
- Cross-platform clipboard — Windows, WSL, Termux, Wayland, X11

---

## Installation

### Option A — Use as your full Neovim config

This repository _is_ a complete Neovim configuration. Clone it into your Neovim config directory:

```sh
# Linux / macOS
git clone https://github.com/kennethaar/neovimlog ~/.config/nvim
```

On first launch you will be prompted for your vault path. It is saved and remembered across sessions.

Platform-specific setup scripts are included for environments that need extra steps:

| Platform | Script |
|----------|--------|
| Windows | `windows_setup.ps1` (PowerShell) |
| Android / Termux | `termux_setup.sh` |

### Option B — Use as a plugin in your existing config (lazy.nvim)

```lua
{
  "kennethaar/neovimlog",
  ft = "markdown",
  opts = {
    vault_path = "~/your-logseq-vault",
  },
}
```

---

## Configuration

All options with their defaults:

```lua
require("logseq").setup({
  vault_path         = nil,          -- REQUIRED: absolute path to your Logseq vault
  journal_format     = "%Y_%m_%d",   -- os.date() format for journal filenames
  indent_size        = 2,            -- Logseq's standard indentation
  fold_on_open       = false,        -- start buffers with all folds closed?
  enable_link_search = true,         -- fuzzy [[ completion in insert mode

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

All keymaps are buffer-local — they only activate inside `.md` files in your vault.

Remap any key at runtime with `:LogseqConfig` without restarting Neovim.

---

## How to use

### Daily workflow

Open Neovim without arguments to land on today's journal. Calendar events sync automatically on open.

### Block navigation

| Key | Action |
|-----|--------|
| `<leader>j` | Next sibling block |
| `<leader>k` | Previous sibling block |
| `<leader>J` | First child block |
| `<leader>K` | Parent block |
| `<Alt-Down>` | Move block (+ subtree) down |
| `<Alt-Up>` | Move block (+ subtree) up |
| `>>` | Indent block with subtree |
| `<<` | Outdent block with subtree |

### Editing

| Key | Action |
|-----|--------|
| `o` (normal) | New sibling block below, enter insert |
| `<CR>` (insert) | Smart split — new sibling after current block |
| `<S-CR>` (insert) | Insert property/continuation line |
| `<Tab>` / `<S-Tab>` | Indent / outdent current block |
| `<C-t>` | Cycle TODO state |

### Links

| Key | Action |
|-----|--------|
| `<CR>` on a link | Follow `[[wikilink]]`, `((block-ref))`, or `#tag` |
| `<CR>` (visual) | Wrap selection in `[[...]]` — or unwrap if already wrapped |

| Syntax | Resolves to |
|--------|-------------|
| `[[Page Name]]` | `pages/Page Name.md` |
| `[[NS/Child]]` | `pages/NS___Child.md` (Logseq namespace encoding) |
| `((block-uuid))` | Block with matching `id::` anywhere in the vault |
| `#tag` | `pages/tag.md` |

### Commands

| Command | Description |
|---------|-------------|
| `:LogseqToday` | Open today's journal |
| `:LogseqNewPage [name]` | Create or open a page |
| `:LogseqConfig` | Interactive keymap and button config |
| `:LogseqCalSync` | Sync calendar manually |
| `:LogseqCalAdd` | Add an ICS calendar URL |
| `:LogseqCalEdit` | View or remove calendar URLs |
| `:LogseqCalRemind` | Set reminder lead time in minutes |

### Calendar setup

```
:LogseqCalAdd
```

Paste your ICS URL (Google Calendar → Settings → "Secret address in iCal format"). Sync runs automatically when today's journal is opened. Requires Python 3 and the packages in `requirements.txt`:

```sh
pip install -r requirements.txt
```

---

## File safety

The plugin never modifies files unless you explicitly edit. Backlinks, queries, and namespace trees are buffer-only — they are never written to disk. The plugin respects Logseq's 2-space indent, `id::` properties, and flat namespace encoding (`NS___Child`), and never touches the `logseq/` system directory.

---

## Documentation

Full in-editor documentation is available via:

```
:help logseq
```

Feature-specific docs are in the `docs/` directory.

---

## License

MIT
