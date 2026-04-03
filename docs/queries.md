# Logseq Simple Queries

Logseq simple queries let you search your vault and display matching results inline within your notes. Results automatically render as a read-only section below each `{{query}}` block, updating dynamically as you edit.

## How to use

### Quick start

Create a query block in your notes:

```markdown
{{query [[ProjectX]] (todo TODO DOING)}}
```

The results will render below as a read-only section showing all blocks that link to `[[ProjectX]]` AND have a TODO or DOING state.

### Opening the Query Builder

| Key | Action |
|-----|--------|
| `<leader>Q` | Open the query builder (form-based UI) |

The builder lets you construct queries without writing S-expressions. You can:
- Add predicates by clicking **[+ Add predicate]**
- Choose between **[AND]** and **[OR]** combination
- Edit or delete existing predicates
- See a live preview of the generated query

**Tip:** If you trigger `<leader>Q` while the cursor is on an existing `{{query}}` block, the builder opens with that query pre-filled for editing.

### Interacting with results

Once a query renders, you can use these keys inside the results section:

| Key/Button | Action |
|------------|--------|
| `[~]` | Toggle query rendering (hide/show results) |
| `<CR>` | Jump to the source block |
| `r` | Refresh this query (re-scan the vault) |
| `t` | Toggle between **List** and **Table** mode |
| `c` | Toggle the column picker (Table mode only) |
| `q` / `<Esc>` | Close column picker or escape from results |

#### List Mode

The default display shows:
- **Bullet point** with block content
- **Page name** on the right
- **Date** (if the block is in a journal file)

```
 • Start the ProjectX kickoff meeting        ProjectX · 2024-01-15
 • Review design specs                       ProjectX · 2024-01-16
```

#### Table Mode

Shows results in a table with configurable columns:
- **Block** — the block content (always shown)
- **Page** — source page name
- **Date** — journal date (if applicable)
- **TODO** — todo state (TODO, DOING, DONE, etc.)
- **Tags** — block tags (comma-separated)

Press `c` to toggle the column picker and choose which columns to display.

### Query Syntax

Queries use S-expression syntax. Below are all supported predicates and combinators:

#### Page Links

```
{{query [[ProjectX]]}}
```

Matches blocks that link to `[[ProjectX]]`. Also supports namespace matching: linking to `[[ProjectX/Design]]` will find all blocks in the `ProjectX` namespace and its children.

**Special:** Use `[[current page]]` to match blocks on the current page:

```
{{query (and [[current page]] (todo TODO))}}
```

#### TODO States

```
{{query (todo TODO DOING)}}
```

Matches blocks with the specified TODO states. Inherits state from parent blocks (Logseq-style).

Supported states: `TODO`, `DOING`, `DONE`, `WAITING`, and any custom states you've defined.

#### Tags

```
{{query (tags project urgent)}}
```

Matches blocks carrying **all** of the specified tags. Tags inherit from parent blocks.

#### Properties

```
{{query (property priority high)}}
```

Matches blocks with a specific property key/value pair. Leave out the value to match blocks that have the property (regardless of value):

```
{{query (property priority)}}
```

#### Page Properties

```
{{query (page-property status archived)}}
```

Matches blocks whose page has the specified page-level property.

#### Date Ranges

```
{{query (between <2024-01-01> <2024-01-31>)}}
```

Matches blocks in journal files within the date range (ISO format: `YYYY-MM-DD`).

#### Combinators

**AND** — All predicates must match:

```
{{query (and [[ProjectX]] (todo TODO DOING))}}
```

**OR** — Any predicate matches:

```
{{query (or [[ProjectX]] [[ProjectY]])}}
```

**NOT** — Negate a predicate:

```
{{query (not (todo DONE))}}
```

#### Complex Queries

Combine predicates and combinators:

```
{{query (and 
  [[ProjectX]]
  (or (todo TODO) (todo DOING))
  (tags important)
  (not (property archived true))
)}}
```

This matches blocks that:
- Link to ProjectX
- Have TODO or DOING state
- Have the `important` tag
- Don't have `archived: true`

## How it works

### Architecture

The query system consists of four main modules:

1. **query_parser.lua** — Parses S-expressions into an AST
2. **query_engine.lua** — Async vault scanner and predicate evaluator
3. **query_ui.lua** — Renders results and manages interactive UI
4. **query_builder.lua** — Floating form UI for building queries

### Query Execution Flow

1. When a buffer is opened or saved, the plugin scans for `{{query ...}}` blocks
2. Each query string is parsed into an Abstract Syntax Tree (AST)
3. The engine launches an async task to scan the vault:
   - Iterates through `pages/` and `journals/` in chunks (50 files at a time)
   - Loads each file from the indexer's cache (or fresh from disk)
   - Evaluates the AST against every block in the file
   - Collects matching results
4. Results are sorted by page name then line number
5. The UI module renders results as virtual lines below the query block
6. Results are displayed in either List or Table mode (toggled with `t`)

### Parsing

The parser uses a **table-dispatched recursive descent approach**:

- **Tokenizer** converts the S-expression string into tokens (words, pages, dates, parentheses)
- **Recursive descent parser** builds an AST tree by dispatching to predicate-specific parsers
- Each predicate type has its own parser function (e.g., `parse_and`, `parse_todo`, `parse_property`)
- Unknown predicates are gracefully skipped (the query won't error, just won't match them)

### Evaluation

The engine evaluates the AST by:

1. **Vault scanning** — Reads every `.md` file in `pages/` and `journals/`
2. **Block context** — For each block, calculates:
   - Effective TODO state (inherited from parents)
   - Effective tags (inherited from parents)
   - Journal date (if the block is in `journals/`)
   - Page-level properties
3. **Predicate matching** — Recursively tests the AST against the block context
4. **Result collection** — Appends matching blocks to an ordered results array

### "Current Page" Support

When the query engine runs, it receives the current page name. Any `[[current page]]` placeholder in a query is replaced with the actual page name, enabling context-aware queries:

```
{{query (and [[current page]] (todo TODO))}}
```

When opened on the ProjectX page, this becomes: `(and [[ProjectX]] (todo TODO))`, finding all TODOs on ProjectX.

### Namespace Matching

Page links support namespace traversal. If you link to `[[ProjectX/Design]]`:

- Direct link: `[[ProjectX/Design]]` matches blocks linking to exactly that page
- **Namespace match:** `[[ProjectX]]` in the query also matches blocks that link to `[[ProjectX/Design]]`, `[[ProjectX/Design/Mockups]]`, etc.

This is implemented in the `block_links_page` function, which checks both exact matches and namespace prefixes.

### Performance

Results are cached aggressively:

- **File cache:** The indexer caches parsed files by mtime, so repeated queries don't re-parse
- **Chunked scanning:** The vault is scanned in 50-file chunks with `vim.schedule()` to avoid blocking the UI
- **Async rendering:** Results are rendered asynchronously, so large result sets don't freeze Neovim

### Read-Only Results

Results are rendered as virtual lines (extmarks) and protected from editing:

- Inserting or editing inside the results section is blocked with `:set nomodifiable`
- Attempting to insert triggers a warning: `[logseq.nvim] Query results are read-only.`
- The section is automatically stripped before saving and re-rendered after save
- Your `.md` file on disk is never modified by the query system

## Configuration

### Keymaps

Customize the query builder trigger in your config:

```lua
require("logseq").setup({
  keymaps = {
    query_builder = "<leader>q",   -- change from default <leader>Q
  }
})
```

### Enabling/Disabling

Queries are enabled by default. To disable them, set in your config:

```lua
require("logseq").setup({
  enable_queries = false,
})
```

## Troubleshooting

### Queries aren't rendering

- Check that `vault_path` is correctly configured
- Ensure the vault has `pages/` or `journals/` directories
- Check the Neovim log (`:messages`) for parse errors

### Results are stale

Press `r` inside the results section to manually refresh, or save the buffer (results auto-refresh on save).

### "Current page" doesn't work

Ensure the current buffer file is within your vault and the plugin can determine the page name from the file path.

### Parse errors

If a query doesn't parse, check:
- Balanced parentheses: `(and ...)` requires closing `)`
- Correct predicate names: `todo` not `task`, `tags` not `tag`
- Proper spacing: `[[page name]]` (with double brackets)
- Date format: `<YYYY-MM-DD>` for between queries
