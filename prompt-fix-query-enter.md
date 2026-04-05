# Fix: Enter key on query result blocks should always navigate to the source file

## Problem

When pressing Enter on a query result row (block) that does NOT contain a `[[wikilink]]` in its text, the cursor simply jumps to the next line instead of opening the source file. Blocks whose content happens to include a `[[link]]` appear to work — but only by accident, via a fallback path.

## Root cause location

The bug lives in the interaction between two functions:

- **`links.lua:199`** — the dispatcher in `M.follow()`:
  ```lua
  if qu_ok and query_ui.in_any_region(bufnr, row) and query_ui.navigate(bufnr) then return end
  ```
  When `navigate()` returns `false`, execution falls through to `link_under_cursor()` (line 201). If the displayed block text contains a `[[link]]` under the cursor, that link is followed (appears to work). Otherwise `normal! j` is executed (line 205) — cursor moves down.

- **`query_ui.lua:708-766`** — `M.navigate()` returns `false` when it should return `true`.

## How navigate() works (and where it breaks)

### Display structure built by `build_display()` (query_ui.lua:297-404)

For list mode with N results, `build_display` returns an array `lines[]` and a source map `smap{}`:

| Index | Content            | smap entry                                           |
|-------|--------------------|------------------------------------------------------|
| 1     | SEP (─── line)     | —                                                    |
| 2     | Header ([~] [LIST])| —                                                    |
| 3     | SEP                | —                                                    |
| 4     | • Result 1 ...     | `{action="navigate", file=path, line=N, page=name}`  |
| 5     | • Result 2 ...     | `{action="navigate", file=path, line=N, page=name}`  |
| ...   | ...                | ...                                                  |
| last  | SEP                | —                                                    |

### How lines are inserted into the buffer (`render_one`, line 485-532)

```
final_lines = {""}  -- blank separator   ← 1-based position: qrow + 2
              + lines from build_display ← 1-based positions: qrow + 3 onwards
```

Key state stored on the query object:
- `q.smap` = the source map (relative keys 1..#lines matching build_display indices)
- `q._lines_count = #final_lines` (includes the leading blank = `1 + #lines`)

### The navigate() lookup (lines 734-762)

```lua
local start_line = qrow + 3          -- 1-based position of lines[1]
local end_line = start_line + q._lines_count - 1
-- ...
local rel = lnum - start_line + 1    -- should map to smap key
local action = q.smap[rel]
```

**The off-by-one:** `_lines_count` includes the leading blank line, but `start_line` already skips past it. This makes `end_line` one line too high. While this doesn't prevent matching (just allows one extra line), the real concern is whether `rel` correctly maps to `smap` keys.

For a result at display position `lines[4]` (first result):
- Buffer 1-based position = `qrow + 3 + 3 = qrow + 6`
- `rel = (qrow + 6) - (qrow + 3) + 1 = 4` → `smap[4]` ✓

The math appears correct for the primary smap path. **Investigate at runtime whether `q.smap` is actually populated, whether `_lines_count` is correct, and whether `qrow` from `query_row_0()` matches the actual extmark position when the user presses Enter.**

### dispatch_smap → open_result_target (lines 686-705, 115-134)

```lua
local function open_result_target(r)
  if r.source_file and r.source_file ~= "" then
    open_file_at(r.source_file, r.line_start)
    return true
  end
  -- fallback: look up source_page in vault/pages/
  ...
  return false
end
```

Block results from `query_engine.lua:233-243` always set `source_file = filepath` (a full path). So `open_result_target` should return `true` for all block results — unless `action.file` is somehow nil when passed through the smap.

## Key files to read

| File | Lines | What to look at |
|------|-------|-----------------|
| `lua/logseq/links.lua` | 188-214 | `M.follow()` — the Enter dispatcher |
| `lua/logseq/query_ui.lua` | 297-404 | `build_display()` — smap construction |
| `lua/logseq/query_ui.lua` | 485-532 | `render_one()` — line insertion & state storage |
| `lua/logseq/query_ui.lua` | 631-648 | `in_any_region()` — region boundary check |
| `lua/logseq/query_ui.lua` | 686-705 | `dispatch_smap()` — action routing |
| `lua/logseq/query_ui.lua` | 708-766 | `navigate()` — the Enter handler |
| `lua/logseq/query_ui.lua` | 115-134 | `open_result_target()` — file opening |
| `lua/logseq/query_engine.lua` | 224-244 | Block result construction (source_file is always set) |

## What to investigate

1. **Is `navigate()` finding the correct query for the cursor line?** The loop at line 734 iterates all queries. If the cursor line falls in one query's range but the loop finds the wrong query first (or skips it), smap lookup fails.

2. **Is the smap populated at navigate-time?** After `render_one` stores `q.smap`, could a re-render or autosave cycle clear/replace it? Check if `remove_section` or `render_all` resets smap before the new render completes.

3. **Does the `_lines_count` include the blank line while `start_line` skips it?** This means `end_line = start_line + _lines_count - 1` overshoots by 1. While not fatal, it indicates the accounting is fragile. The clean fix: store `#lines` (build_display output count) instead of `#final_lines`.

4. **When `navigate()` returns false, should `links.follow()` still fall through to generic link-following?** The cursor is inside a query region — falling through to `link_under_cursor()` and then `j` is incorrect behavior. The query region should be an opaque boundary.

## How to fix

The fix should address two layers:

### Layer 1: Make `navigate()` reliably return `true` for result lines

- Verify that `_lines_count` and `start_line` are consistent. Consider storing `#lines` (from build_display) instead of `#final_lines` in `_lines_count`, so the range calculation in navigate becomes: `end_line = start_line + lines_count - 1` — matching exactly the display region without an off-by-one.
- Add a safeguard: if `smap[rel]` is nil but `rel` falls within the result line range (between the header separator and the bottom separator), use the existing `list_result_index_at_line` fallback. Currently this fallback only runs after `dispatch_smap` fails, but it should ALSO run when `smap[rel]` is nil.

### Layer 2: Prevent fallthrough to `link_under_cursor()` for query regions

In `links.lua:follow()`, the current logic at line 199:
```lua
if qu_ok and query_ui.in_any_region(bufnr, row) and query_ui.navigate(bufnr) then return end
```

This falls through when navigate returns false. **The cursor is inside a query region — it should not fall through to generic link-following.** Change this so that when `in_any_region` is true, the function returns early regardless of navigate's return value. Query result lines are synthetic — running `link_under_cursor()` on them is nonsensical.

Suggested structure:
```lua
if qu_ok and query_ui.in_any_region(bufnr, row) then
  query_ui.navigate(bufnr)
  return
end
```

This makes query regions an opaque boundary: Enter either navigates to the source or does nothing. It never accidentally follows a wikilink embedded in display text or moves the cursor down.

## Constraints

- Do not use nested if/else chains. Use early returns and guard clauses.
- Do not add feature flags, backwards-compatibility shims, or speculative abstractions.
- Keep the fix minimal — only change what is needed to fix the described behavior.
- Ensure both list mode and table mode work correctly.
- The fix must handle the fallback path (stale smap / missing extmark) gracefully.
