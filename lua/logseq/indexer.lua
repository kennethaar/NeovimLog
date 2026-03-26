--- logseq.nvim indexer
--- Async vault scanner for backlink discovery.
--- Uses shared util.normalize (audit #8).
--- Cache stores only what's needed for backlinks, not full parse trees (audit #20).

local parser = require("logseq.parser")
local util = require("logseq.util")
local config = require("logseq.config")

local M = {}

-- ── Cache ─────────────────────────────────────────────────────────────

M._cache = {}

function M.invalidate(filepath)
  M._cache[util.normalize(filepath)] = nil
end

function M.invalidate_all()
  M._cache = {}
end

-- ── Page name derivation ──────────────────────────────────────────────

function M.page_name_from_file(filepath)
  local vault = config.current.vault_path
  if not vault or vault == "" then return nil end

  local norm_vault = util.normalize(vault)
  local norm_file = util.normalize(filepath)

  if norm_file:sub(1, #norm_vault + 1) ~= norm_vault .. "/" then return nil end

  local rel = norm_file:sub(#norm_vault + 2)

  local journal_name = rel:match("^journals/(.+)%.md$")
  if journal_name then
    return util.format_journal_date(journal_name, vault) or journal_name
  end

  local page_name = rel:match("^pages/(.+)%.md$")
  if page_name then return util.decode_filename(page_name) end

  return nil
end

-- ── Alias helpers ─────────────────────────────────────────────────────

-- Split a Logseq "alias:: a, b, c" value into trimmed name strings.
local function parse_alias_list(alias_str)
  local aliases = {}
  for part in alias_str:gmatch("[^,]+") do
    local trimmed = part:match("^%s*(.-)%s*$")
    if trimmed ~= "" then aliases[#aliases + 1] = trimmed end
  end
  return aliases
end

-- Return the alias list defined in the page-properties of a vault file.
-- Uses the indexer cache when the file has already been parsed; reads and
-- caches it otherwise, so this is at most one extra disk read per session.
local function get_page_aliases(filepath, uv)
  if not filepath then return {} end
  local norm = util.normalize(filepath)
  local page_props

  local cached = M._cache[norm]
  if cached then
    page_props = cached.parsed.page_properties
  else
    local stat = uv.fs_stat(filepath)
    if not stat then return {} end
    local fd = uv.fs_open(filepath, "r", 438)
    if not fd then return {} end
    local content = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    if not content then return {} end
    local lines = vim.split(content, "\n", { plain = true })
    local parsed = parser.parse(lines)
    M._cache[norm] = { mtime = stat.mtime.sec, parsed = parsed, lines = lines, content = content }
    page_props = parsed.page_properties
  end

  local alias_str = page_props.alias or page_props.aliases
  if not alias_str or alias_str == "" then return {} end
  return parse_alias_list(alias_str)
end



-- Journal filenames use _ (2024_01_15) but Logseq page titles use - (2024-01-15).
-- Normalise all ISO-date refs to dashes so both link styles are matched.
local function norm_link(link)
  return (link:gsub("^(%d%d%d%d)_(%d%d)_(%d%d)$", "%1-%2-%3"))
end

local function compute_all_refs(flat)
  local memo = {}
  for _, block in ipairs(flat) do
    local refs = {}
    for _, link in ipairs(block.links) do refs[norm_link(link)] = true end
    for _, tag in ipairs(block.tags) do refs[tag] = true end
    if block.parent and memo[block.parent] then
      for ref in pairs(memo[block.parent]) do refs[ref] = true end
    end
    memo[block] = refs
  end
  return memo
end

-- ── Context tree extraction ───────────────────────────────────────────

local function strip_bullet(line_text)
  return line_text:match("^%s*%- (.*)$") or line_text:match("^%s*(.*)$") or line_text
end

local function extract_context(block, lines)
  local ancestors = {}
  local cur = block.parent
  while cur do
    table.insert(ancestors, cur)
    cur = cur.parent
  end
  for i = 1, math.floor(#ancestors / 2) do
    local j = #ancestors - i + 1
    ancestors[i], ancestors[j] = ancestors[j], ancestors[i]
  end

  local result = {}
  local base_indent = 2

  for i, anc in ipairs(ancestors) do
    table.insert(result, {
      text = strip_bullet(lines[anc.line_start] or ""),
      source_line = anc.line_start,
      indent = base_indent + (i - 1) * 2,
      is_match = false,
      is_ancestor = true,
    })
  end

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

-- ── Candidate scanner ─────────────────────────────────────────────────

local function build_needles(page_name)
  local needles = { "[[" .. page_name .. "]]" }
  -- Journal page title uses dashes (2024-01-15) but files are often named with underscores
  -- (2024_01_15).  Include both forms so content_matches catches either link style.
  local alt = page_name:gsub("^(%d%d%d%d)-(%d%d)-(%d%d)$", "%1_%2_%3")
  if alt ~= page_name then table.insert(needles, "[[" .. alt .. "]]") end
  local tag_flat = page_name:gsub("%s+", "_"):gsub("/", "_")
  if tag_flat:match("^[%w_%-]+$") then table.insert(needles, "#" .. tag_flat) end
  if page_name:match("/") then
    local tag_hier = page_name:gsub("%s+", "_")
    if tag_hier:match("^[%w_%-/]+$") then table.insert(needles, "#" .. tag_hier) end
  end
  -- Org-mode / Logseq SCHEDULED and DEADLINE timestamps: <2026-04-01 Wed>
  -- Only ISO-format dates (the default journal page-name format) are supported here.
  if page_name:match("^%d%d%d%d-%d%d-%d%d$") then
    table.insert(needles, "<" .. page_name)
  end
  return needles
end

local function content_matches(haystack, needles)
  for _, needle in ipairs(needles) do
    if haystack:find(needle, 1, true) then return true end
  end
  return false
end

local function list_md_files(dirs, uv)
  local files = {}
  for _, dir in ipairs(dirs) do
    local handle = uv.fs_scandir(dir)
    if handle then
      while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then break end
        if name:sub(-3) == ".md" and ftype ~= "directory" then
          table.insert(files, dir .. "/" .. name)
        end
      end
    end
  end
  return files
end

--- Return true if any ancestor of block was already recorded as a match.
--- Marks the ancestor set once, so repeated queries on the same block are O(1).
local function is_dominated(block, matched_set)
  local cur = block.parent
  while cur do
    if matched_set[cur.line_start] then return true end
    cur = cur.parent
  end
  return false
end

--- Load or return cached parse data for one file.
--- Returns file_lines, parsed — or nil if unreadable / not matching.
local function load_file(filepath, norm, needles, uv)
  local stat  = uv.fs_stat(filepath)
  local mtime = stat and stat.mtime.sec or 0
  local cached = M._cache[norm]

  if cached and cached.mtime == mtime then
    if not content_matches(cached.content, needles) then return nil end
    return cached.lines, cached.parsed
  end

  local fd = uv.fs_open(filepath, "r", 438)
  if not fd then return nil end
  local content = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)

  if not content or not content_matches(content, needles) then return nil end

  local lines = vim.split(content, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  local parsed = parser.parse(lines)
  M._cache[norm] = { mtime = mtime, parsed = parsed, lines = lines, content = content }
  return lines, parsed
end

--- Scan one file for blocks that reference any name in target_names; append results.
--- target_names is a set (table keyed by string) covering the canonical page name
--- plus all aliases declared on that page.
local function process_file(filepath, norm, target_names, needles, uv, results)
  local file_lines, parsed = load_file(filepath, norm, needles, uv)
  if not file_lines then return end

  -- Self-reference by path is already excluded upstream via norm_exclude.
  local source_page = M.page_name_from_file(filepath) or vim.fn.fnamemodify(filepath, ":t:r")

  local flat     = parser.flatten(parsed.blocks)
  local all_refs = compute_all_refs(flat)
  local matched  = {}  -- line_start → true for already-added blocks

  for _, block in ipairs(flat) do
    local refs = all_refs[block]
    local is_ref = false
    if refs then
      for name in pairs(target_names) do
        if refs[name] then is_ref = true; break end
      end
    end
    if is_ref and not is_dominated(block, matched) then
      matched[block.line_start] = true
      table.insert(results, {
        source_page    = source_page,
        source_file    = filepath,
        context_blocks = extract_context(block, file_lines),
        is_scheduled   = block.properties.SCHEDULED ~= nil or block.properties.DEADLINE ~= nil
                      or block.content:find("SCHEDULED::", 1, true) ~= nil
                      or block.content:find("DEADLINE::", 1, true) ~= nil,
      })
    end
  end

  -- Page-level property refs: [[ProjectX]] or #ProjectX in page properties
  -- (e.g. "tags:: [[ProjectX]]") create a backlink even when no block links to the page.
  -- Use the first block as the context anchor if present and not already matched.
  local p_refs = parser.page_property_refs(parsed.page_properties)
  local page_prop_match = false
  for name in pairs(target_names) do
    if p_refs[name] then page_prop_match = true; break end
  end
  if page_prop_match and flat[1] and not matched[flat[1].line_start] then
    table.insert(results, {
      source_page    = source_page,
      source_file    = filepath,
      context_blocks = extract_context(flat[1], file_lines),
      is_scheduled   = false,
    })
  end
end

-- ── Main finder (Async) ───────────────────────────────────────────────

---@param page_name string
---@param exclude_file string|nil
---@param on_complete function
---@param on_progress function|nil
function M.find_backlinks(page_name, exclude_file, on_complete, on_progress)
  local raw_vault = config.current.vault_path
  if not raw_vault or raw_vault == "" then return on_complete({}) end
  -- Normalize once: expands ~, resolves symlinks, strips trailing slash.
  -- libuv (fs_scandir/fs_open) does NOT expand ~ on its own.
  local vault = util.normalize(raw_vault)

  local search_dirs = {}
  if vim.fn.isdirectory(vault .. "/pages")   == 1 then table.insert(search_dirs, vault .. "/pages")   end
  if vim.fn.isdirectory(vault .. "/journals") == 1 then table.insert(search_dirs, vault .. "/journals") end
  if #search_dirs == 0 then return on_complete({}) end

  local uv = vim.uv or vim.loop

  -- Build the target set: canonical page name + every alias declared on the page.
  -- A link to any alias counts as a backlink to the canonical page.
  local target_names = { [page_name] = true }
  for _, alias in ipairs(get_page_aliases(exclude_file, uv)) do
    target_names[alias] = true
  end

  -- Collect needles for every target name, deduped via a set.
  local needle_set = {}
  for name in pairs(target_names) do
    for _, n in ipairs(build_needles(name)) do needle_set[n] = true end
  end
  local needles = {}
  for n in pairs(needle_set) do needles[#needles + 1] = n end

  local norm_exclude = exclude_file and util.normalize(exclude_file) or nil
  local all_files = list_md_files(search_dirs, uv)
  local results   = {}

  if #all_files == 0 then return on_complete({}) end

  local i = 1

  local function process_chunk()
    local chunk_end = math.min(i + 49, #all_files)

    for j = i, chunk_end do
      local filepath = all_files[j]
      local norm     = util.normalize(filepath)
      if norm ~= norm_exclude then
        process_file(filepath, norm, target_names, needles, uv, results)
      end
    end

    if on_progress then on_progress(chunk_end, #all_files) end

    if chunk_end < #all_files then
      i = chunk_end + 1
      vim.schedule(process_chunk)
    else
      table.sort(results, function(a, b)
        -- Scheduled/deadline blocks surface first; ties broken alphabetically
        if a.is_scheduled ~= b.is_scheduled then return a.is_scheduled end
        return a.source_page < b.source_page
      end)
      on_complete(results)
    end
  end

  process_chunk()
end

return M
