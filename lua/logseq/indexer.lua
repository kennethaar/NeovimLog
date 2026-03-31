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

-- ── Ref helpers ───────────────────────────────────────────────────────

-- Return true if any key in target_names exists in refs.
local function matches_target(refs, target_names)
  for name in pairs(target_names) do
    if refs[name] then return true end
  end
  return false
end

-- Return true if the block has a SCHEDULED or DEADLINE marker (any case, single or double colon).
-- block.is_scheduled is set by the parser for both continuation-line and inline markers.
local function is_block_scheduled(block)
  return block.is_scheduled == true
      or block.properties.SCHEDULED ~= nil
      or block.properties.scheduled ~= nil
      or block.properties.DEADLINE  ~= nil
      or block.properties.deadline  ~= nil
end

--- Extract the first SCHEDULED or DEADLINE ISO date "YYYY-MM-DD" from a block.
--- Returns date_iso (string|nil), is_deadline (bool).
local function block_sched_date(block, file_lines)
  local sv = util.prop_ci(block.properties, "scheduled")
  if sv then
    local d = sv:match("<(%d%d%d%d%-%d%d%-%d%d)") or sv:match("(%d%d%d%d%-%d%d%-%d%d)")
    if d then return d, false end
  end
  local dv = util.prop_ci(block.properties, "deadline")
  if dv then
    local d = dv:match("<(%d%d%d%d%-%d%d%-%d%d)") or dv:match("(%d%d%d%d%-%d%d%-%d%d)")
    if d then return d, true end
  end
  -- Fallback: scan continuation lines when property wasn't parsed into properties table.
  for li = block.line_start + 1, block.line_end do
    local line = file_lines[li]
    if line then
      local ll = line:lower()
      if ll:find("scheduled:", 1, true) then
        local d = line:match("<(%d%d%d%d%-%d%d%-%d%d)") or line:match("(%d%d%d%d%-%d%d%-%d%d)")
        if d then return d, false end
      elseif ll:find("deadline:", 1, true) then
        local d = line:match("<(%d%d%d%d%-%d%d%-%d%d)") or line:match("(%d%d%d%d%-%d%d%-%d%d)")
        if d then return d, true end
      end
    end
  end
  -- Also check the block's own content for inline "SCHEDULED: <date>" on the same line.
  local lc = block.content:lower()
  if lc:find("scheduled:", 1, true) then
    local d = block.content:match("<(%d%d%d%d%-%d%d%-%d%d)")
    if d then return d, false end
  elseif lc:find("deadline:", 1, true) then
    local d = block.content:match("<(%d%d%d%d%-%d%d%-%d%d)")
    if d then return d, true end
  end
  return nil, nil
end

--- Return true when the block's TODO keyword is DONE or CANCELLED (case-insensitive).
local function block_is_done(content)
  local c = content:lower()
  return vim.startswith(c, "done ") or c == "done"
      or vim.startswith(c, "cancelled ") or c == "cancelled"
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
    if matches_target(all_refs[block], target_names) and not is_dominated(block, matched) then
      matched[block.line_start] = true
      table.insert(results, {
        source_page    = source_page,
        source_file    = filepath,
        context_blocks = extract_context(block, file_lines),
        is_scheduled   = is_block_scheduled(block),
      })
    end
  end

  -- Page-level property refs: [[ProjectX]] or #ProjectX in page properties
  -- (e.g. "tags:: [[ProjectX]]") create a backlink even when no block links to the page.
  -- Use the first block as the context anchor if present and not already matched.
  local p_refs = parser.page_property_refs(parsed.page_properties)
  if matches_target(p_refs, target_names) and flat[1] and not matched[flat[1].line_start] then
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
  -- For journal pages with a custom title format (e.g. "Apr 1st, 2026"), org-mode
  -- SCHEDULED/DEADLINE timestamps always embed the underlying ISO date <2026-04-01>.
  -- Add the ISO form so those tasks are found regardless of the vault's page-title format.
  if exclude_file then
    local stem = exclude_file:match("[/\\]journals[/\\](%d%d%d%d[_%-]%d%d[_%-]%d%d)%.md$")
    if stem then target_names[stem:gsub("_", "-")] = true end
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

-- ── Scheduled / Deadline task scanner ────────────────────────────────

--- Async: scan the entire vault for incomplete scheduled/deadline blocks.
--- Calls on_complete({ overdue = [...], upcoming = [...] }) where each entry is:
---   { source_page, source_file, date_iso, is_deadline, context_blocks }
--- overdue  — scheduled date < today_iso AND block is not DONE/CANCELLED
--- upcoming — today_iso <= date <= today+6 AND block is not DONE/CANCELLED
---@param today_iso  string  "YYYY-MM-DD"
---@param on_complete function
function M.find_scheduled_blocks(today_iso, on_complete)
  local raw_vault = config.current.vault_path
  if not raw_vault or raw_vault == "" then
    return vim.schedule(function() on_complete({ overdue = {}, upcoming = {} }) end)
  end
  local vault = util.normalize(raw_vault)

  local search_dirs = {}
  if vim.fn.isdirectory(vault .. "/pages")   == 1 then search_dirs[#search_dirs+1] = vault .. "/pages"   end
  if vim.fn.isdirectory(vault .. "/journals") == 1 then search_dirs[#search_dirs+1] = vault .. "/journals" end
  if #search_dirs == 0 then
    return vim.schedule(function() on_complete({ overdue = {}, upcoming = {} }) end)
  end

  local uv        = vim.uv or vim.loop
  local all_files = list_md_files(search_dirs, uv)
  if #all_files == 0 then
    return vim.schedule(function() on_complete({ overdue = {}, upcoming = {} }) end)
  end

  -- today+6 is the upper bound of the upcoming window (7 days inclusive)
  local upcoming_end = os.date("%Y-%m-%d", os.time() + 6 * 86400)
  local overdue, upcoming = {}, {}
  local i = 1

  local function process_chunk()
    local chunk_end = math.min(i + 49, #all_files)

    for j = i, chunk_end do
      local filepath = all_files[j]
      local norm     = util.normalize(filepath)
      local stat     = uv.fs_stat(filepath)
      if stat then
        local file_lines, parsed
        local cached = M._cache[norm]
        if cached and cached.mtime == stat.mtime.sec then
          file_lines = cached.lines
          parsed     = cached.parsed
        else
          local fd = uv.fs_open(filepath, "r", 438)
          if fd then
            local content = uv.fs_read(fd, stat.size, 0)
            uv.fs_close(fd)
            if content then
              file_lines = vim.split(content, "\n", { plain = true })
              if #file_lines > 0 and file_lines[#file_lines] == "" then table.remove(file_lines) end
              parsed     = parser.parse(file_lines)
              M._cache[norm] = { mtime = stat.mtime.sec, parsed = parsed, lines = file_lines, content = content }
            end
          end
        end

        if parsed and file_lines then
          local source_page = M.page_name_from_file(filepath) or vim.fn.fnamemodify(filepath, ":t:r")
          for _, block in ipairs(parser.flatten(parsed.blocks)) do
            if block.is_scheduled and not block_is_done(block.content) then
              local date_iso, is_deadline = block_sched_date(block, file_lines)
              if date_iso then
                local entry = {
                  source_page    = source_page,
                  source_file    = filepath,
                  date_iso       = date_iso,
                  is_deadline    = is_deadline,
                  context_blocks = extract_context(block, file_lines),
                }
                if date_iso < today_iso then
                  overdue[#overdue+1] = entry
                elseif date_iso <= upcoming_end then
                  upcoming[#upcoming+1] = entry
                end
              end
            end
          end
        end
      end
    end

    i = chunk_end + 1
    if i > #all_files then
      table.sort(overdue,  function(a, b) return a.date_iso < b.date_iso end)
      table.sort(upcoming, function(a, b) return a.date_iso < b.date_iso end)
      vim.schedule(function() on_complete({ overdue = overdue, upcoming = upcoming }) end)
    else
      vim.schedule(process_chunk)
    end
  end

  vim.schedule(process_chunk)
end

return M
