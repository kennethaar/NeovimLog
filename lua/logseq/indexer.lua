--- logseq.nvim indexer
--- Backlink finder. Given a page name, finds every block in the vault whose
--- effective_refs includes that page — including inherited refs from ancestor
--- blocks and the page itself (path-refs).
--- Pure Lua, cross-platform (no grep/shell dependency).

local parser = require("logseq.parser")
local links_mod = require("logseq.links")
local config = require("logseq.config")

local M = {}

-- ── Path normalization ────────────────────────────────────────────────

--- Normalize a path: resolve symlinks, forward-slash, lowercase on Windows.
---@param p string
---@return string
local function norm_path(p)
  local resolved = vim.fn.resolve(vim.fn.expand(p)):gsub("\\", "/")
  if vim.fn.has("win32") == 1 then resolved = resolved:lower() end
  return resolved
end

-- ── Cache ─────────────────────────────────────────────────────────────

M._cache = {} -- norm_path → { mtime, parsed, lines, content }

--- Invalidate a single file's cache entry.
---@param filepath string
function M.invalidate(filepath)
  M._cache[norm_path(filepath)] = nil
end

--- Invalidate the entire cache.
function M.invalidate_all()
  M._cache = {}
end

-- ── Page name derivation ──────────────────────────────────────────────

--- Derive the Logseq page name from a filepath.
--- pages/BJJ___Techniques___Triangle.md → "BJJ/Techniques/Triangle"
--- journals/2026_03_17.md → "2026_03_17"
---@param filepath string  full path to the .md file
---@return string|nil
function M.page_name_from_file(filepath)
  local vault = config.current.vault_path
  if not vault or vault == "" then return nil end

  -- Normalize for prefix comparison but do NOT lowercase —
  -- the page name is extracted from the path and must keep its casing.
  local norm_vault = vim.fn.resolve(vim.fn.expand(vault)):gsub("\\", "/")
  local norm_file = vim.fn.resolve(vim.fn.expand(filepath)):gsub("\\", "/")

  -- Case-insensitive prefix check on Windows
  local vault_cmp = vim.fn.has("win32") == 1 and norm_vault:lower() or norm_vault
  local file_cmp = vim.fn.has("win32") == 1 and norm_file:lower() or norm_file
  if file_cmp:sub(1, #vault_cmp) ~= vault_cmp then return nil end

  local rel = norm_file:sub(#norm_vault + 2) -- skip trailing /

  local journal_name = rel:match("^journals/(.+)%.md$")
  if journal_name then return journal_name end

  local page_name = rel:match("^pages/(.+)%.md$")
  if page_name then
    return links_mod.filename_to_page(page_name .. ".md")
  end

  return nil
end

-- ── Effective refs computation ────────────────────────────────────────

--- Compute the full set of inherited references for every block in a flat list.
--- Uses single-pass memoization: since parser.flatten() is depth-first,
--- every parent appears before its children, so the parent's refs are
--- already computed when we reach each child.
---
--- effective_refs(block) = own links ∪ own tags ∪ effective_refs(parent) ∪ {page_name}
---
--- Note: property values wrapped in [[links]] are already extracted into
--- block.links by the parser (parser.lua:151-154), so no extra scan needed.
---@param flat LogseqBlock[]
---@param page_name string
---@return table<LogseqBlock, table<string, boolean>>
local function compute_all_refs(flat, page_name)
  local memo = {} ---@type table<LogseqBlock, table<string,boolean>>

  for _, block in ipairs(flat) do
    local refs = {}

    -- Own direct links (includes links extracted from property values by the parser)
    for _, link in ipairs(block.links) do
      refs[link] = true
    end

    -- Own direct tags
    for _, tag in ipairs(block.tags) do
      refs[tag] = true
    end

    -- Inherited from parent (already memoized — depth-first guarantees this)
    if block.parent and memo[block.parent] then
      for ref in pairs(memo[block.parent]) do
        refs[ref] = true
      end
    end

    -- Page-level inheritance
    refs[page_name] = true

    memo[block] = refs
  end

  return memo
end

-- ── Context tree extraction ───────────────────────────────────────────

--- Strip a buffer line to its visible content (remove leading whitespace and "- ").
---@param line_text string
---@return string
local function strip_bullet(line_text)
  return line_text:match("^%s*%- (.*)$")
      or line_text:match("^%s*(.*)$")
      or line_text
end

--- Build a context tree for a matching block: ancestors + the block + all children.
--- Returns a flat list of ContextBlock entries with normalized indentation.
---@param block LogseqBlock
---@param lines string[]  buffer lines for extracting text
---@return ContextBlock[]
local function extract_context(block, lines)
  local ancestors = {}
  local cur = block.parent
  while cur do
    table.insert(ancestors, 1, cur)
    cur = cur.parent
  end

  local result = {}
  local base_indent = 2 -- page name at 0, first context block at 2

  -- Ancestors as single-line breadcrumbs
  for i, anc in ipairs(ancestors) do
    table.insert(result, {
      text = strip_bullet(lines[anc.line_start] or ""),
      source_line = anc.line_start,
      indent = base_indent + (i - 1) * 2,
      is_match = false,
      is_ancestor = true,
    })
  end

  -- The matching block and all its descendants
  local match_indent = base_indent + #ancestors * 2

  local function add_subtree(b, indent)
    table.insert(result, {
      text = strip_bullet(lines[b.line_start] or ""),
      source_line = b.line_start,
      indent = indent,
      is_match = (b.line_start == block.line_start),
      is_ancestor = false,
    })
    for _, child in ipairs(b.children) do
      add_subtree(child, indent + 2)
    end
  end

  add_subtree(block, match_indent)
  return result
end

-- ── Candidate scanner (pure Lua, cross-platform) ─────────────────────

--- Build the set of literal search strings that indicate a file might
--- reference this page name. Uses plain string.find — no regex, no escaping.
---@param page_name string
---@return string[]
local function build_needles(page_name)
  local needles = { "[[" .. page_name .. "]]" }

  -- Tag form: spaces→underscores, slashes→underscores (#Project_Alpha)
  local tag_flat = page_name:gsub("%s+", "_"):gsub("/", "_")
  if not tag_flat:match("[^%w_%-]") then
    table.insert(needles, "#" .. tag_flat)
  end

  -- Hierarchical tag form: spaces→underscores, slashes kept (#BJJ/Techniques)
  if page_name:match("/") then
    local tag_hier = page_name:gsub("%s+", "_")
    if not tag_hier:match("[^%w_%-/]") then
      table.insert(needles, "#" .. tag_hier)
    end
  end

  return needles
end

--- Check whether a string contains any of the needle strings (plain match).
---@param haystack string  file content
---@param needles string[]
---@return boolean
local function content_matches(haystack, needles)
  for _, needle in ipairs(needles) do
    if haystack:find(needle, 1, true) then return true end
  end
  return false
end

--- List all .md files in the given directories.
---@param dirs string[]
---@return string[]
local function list_md_files(dirs)
  local files = {}
  for _, dir in ipairs(dirs) do
    local found = vim.fn.glob(dir .. "/*.md", true, true)
    vim.list_extend(files, found)
  end
  return files
end

-- ── Domination helper ─────────────────────────────────────────────────

--- Check if a block is a descendant of any block in a set (keyed by line_start).
---@param block LogseqBlock
---@param ancestor_lines table<integer, boolean>  set of line_start values
---@return boolean
local function is_dominated(block, ancestor_lines)
  local cur = block.parent
  while cur do
    if ancestor_lines[cur.line_start] then return true end
    cur = cur.parent
  end
  return false
end

-- ── Main finder ───────────────────────────────────────────────────────

---@class BacklinkResult
---@field source_page    string
---@field source_file    string
---@field context_blocks ContextBlock[]

---@class ContextBlock
---@field text           string
---@field source_line    integer
---@field indent         integer
---@field is_match       boolean
---@field is_ancestor    boolean

--- Find all backlinks for a given page name.
---@param page_name string
---@param exclude_file string|nil  current file to exclude
---@return BacklinkResult[]
function M.find_backlinks(page_name, exclude_file)
  local vault = config.current.vault_path
  if not vault then return {} end

  local search_dirs = {}
  local pages_dir = vault .. "/pages"
  local journals_dir = vault .. "/journals"
  if vim.fn.isdirectory(pages_dir) == 1 then table.insert(search_dirs, pages_dir) end
  if vim.fn.isdirectory(journals_dir) == 1 then table.insert(search_dirs, journals_dir) end
  if #search_dirs == 0 then return {} end

  local norm_exclude = exclude_file and norm_path(exclude_file) or nil
  local needles = build_needles(page_name)
  local all_files = list_md_files(search_dirs)
  local results = {}

  for _, filepath in ipairs(all_files) do
    local norm = norm_path(filepath)
    if norm == norm_exclude then goto next_file end

    local stat = (vim.uv or vim.loop).fs_stat(filepath)
    local mtime = stat and stat.mtime.sec or 0
    local cached = M._cache[norm]

    local file_content, file_lines, parsed

    if cached and cached.mtime == mtime then
      -- Use cached data; check needle match against cached content
      if not content_matches(cached.content, needles) then goto next_file end
      file_lines = cached.lines
      parsed = cached.parsed
    else
      -- Read the file
      local f = io.open(filepath, "r")
      if not f then goto next_file end
      file_content = f:read("*a")
      f:close()

      -- Quick check: does this file even mention the page?
      if not content_matches(file_content, needles) then goto next_file end

      file_lines = vim.split(file_content, "\n", { plain = true })
      if #file_lines > 0 and file_lines[#file_lines] == "" then
        table.remove(file_lines)
      end

      parsed = parser.parse(file_lines)
      M._cache[norm] = {
        mtime = mtime,
        parsed = parsed,
        lines = file_lines,
        content = file_content,
      }
    end

    local source_page = M.page_name_from_file(filepath) or vim.fn.fnamemodify(filepath, ":t:r")

    -- Skip self-references at the file level
    if source_page == page_name then goto next_file end

    -- Compute effective_refs for all blocks in one memoized pass
    local flat = parser.flatten(parsed.blocks)
    local all_refs = compute_all_refs(flat, source_page)

    -- Collect the shallowest matching blocks (skip descendants of already-matched blocks)
    local matching_blocks = {}
    local matched_lines = {} ---@type table<integer, boolean>

    for _, block in ipairs(flat) do
      local refs = all_refs[block]
      if not refs or not refs[page_name] then goto next_block end
      if is_dominated(block, matched_lines) then goto next_block end

      table.insert(matching_blocks, block)
      matched_lines[block.line_start] = true

      ::next_block::
    end

    for _, block in ipairs(matching_blocks) do
      table.insert(results, {
        source_page = source_page,
        source_file = filepath,
        context_blocks = extract_context(block, file_lines),
      })
    end

    ::next_file::
  end

  table.sort(results, function(a, b) return a.source_page < b.source_page end)
  return results
end

return M
