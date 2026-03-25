# Backlinks

The backlinks panel shows every page and journal entry in your vault that links to the page you are currently reading.

## How to use

| Key | Action |
|-----|--------|
| `<leader>b` | Toggle the backlinks panel on/off |
| `<CR>` on an entry | Jump to the source file at that line |

## How it works

When toggled on, the plugin performs an async text search across `pages/` and `journals/` for the current page's wikilink (e.g. `[[My Project]]`). Results are injected as a read-only block at the bottom of the buffer, grouped by source page.

The section is wrapped in hidden markers so it can be cleanly removed when toggled off. It is also automatically stripped before any save and re-rendered after, so your `.md` file on disk is never modified by it.

When any vault file is saved, all other open buffers that have the backlinks panel visible are refreshed automatically.

## Configuration

Toggle visibility of the winbar `b🖇️` button via `:LogseqConfig` → WINBAR BUTTONS.
