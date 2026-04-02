# Deduplication

Removes duplicate lines from pages and journals. Works block-tree-aware: when a block appears more than once, the duplicate is removed and its children are merged into the bottom of the first copy's children — recursively at all depths.

A backup of the original file is saved to `vault/deduped/` before any changes are made.

## Commands

| Command | Action |
|---------|--------|
| `:LogseqDedup` | Dedup the current buffer. Shows how many lines were removed. |
| `:LogseqDedupVault` | Dedup every file in `pages/` and `journals/`. Shows a final summary. |

## Automatic dedup after merge/rename

When you rename a page and it merges into an existing one, dedup runs silently on the merged result. No manual step needed.

## How duplicate blocks are handled

If a block appears more than once, the second copy is removed and its children are moved to the bottom of the first copy's children:

**Before:**
```
- GTD Weekly Review
  - Child A
- GTD Weekly Review
  - Child C
```

**After:**
```
- GTD Weekly Review
  - Child A
  - Child C
```

Duplicate children within the merged result are also removed. The same logic applies recursively to all depths.

Empty lines and `---` section dividers are never removed.

## Backups

Before modifying any file, the original is copied to:

```
vault/deduped/<filename>_<YYYY-MM-DD_HHMMSS>.md
```

If two backups would have the same timestamp, `_1`, `_2`, ... is appended. Backups are never deduped themselves.

## Undo

`:LogseqDedup` is a single undo entry — pressing `u` restores all removed lines at once.
