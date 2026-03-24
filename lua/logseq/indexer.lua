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
  if journal_name then return journal_name end

  local page_name = rel:match("^pages/(.+)%.md$")
  if page_name then return util.decode_filename(page_name) end

  return nil
end

-- ── Effective refs computation ────────────────────────────────────────

local function compute_all_refs(flat, page_name)
  local memo = {}
  for _, block in ipairs(flat) do
    local refs = {}
    for _, link in ipairs(block.links) do refs[link] = true end
    for _, tag in ipairs(block.tags) do refs[tag] = true end
    if block.parent and memo[block.parent] then
      for ref in pairs(memo[block.parent]) do refs[ref] = true end
    end
    refs[page_name] = true
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
    table.insert(ancestors, 1, cur)
    cur = cur.parent
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
  local tag_flat = page_name:gsub("%s+", "_"):gsub("/", "_")
  if not tag_flat:match("[^%w_%-]") then table.insert(needles, "#" .. tag_flat) end
  if page_name:match("/") then
    local tag_hier = page_name:gsub("%s+", "_")
    if not tag_hier:match("[^%w_%-/]") then table.insert(needles, "#" .. tag_hier) end
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

--- Scan one file for blocks that reference page_name; append results.
local function process_file(filepath, norm, page_name, needles, uv, results)
  local file_lines, parsed = load_file(filepath, norm, needles, uv)
  if not file_lines then return end

  local source_page = M.page_name_from_file(filepath) or vim.fn.fnamemodify(filepath, ":t:r")
  if source_page == page_name then return end

  local flat      = parser.flatten(parsed.blocks)
  local all_refs  = compute_all_refs(flat, source_page)
  local matched   = {}  -- line_start → true for already-added blocks

  for _, block in ipairs(flat) do
    local refs = all_refs[block]
    if refs and refs[page_name] and not is_dominated(block, matched) then
      matched[block.line_start] = true
      table.insert(results, {
        source_page    = source_page,
        source_file    = filepath,
        context_blocks = extract_context(block, file_lines),
      })
    end
  end
end

-- ── Main finder (Async) ───────────────────────────────────────────────

---@param page_name string
---@param exclude_file string|nil
---@param on_complete function
---@param on_progress function|nil
function M.find_backlinks(page_name, exclude_file, on_complete, on_progress)
  local vault = config.current.vault_path
  if not vault then return on_complete({}) end

  local search_dirs = {}
  if vim.fn.isdirectory(vault .. "/pages")   == 1 then table.insert(search_dirs, vault .. "/pages")   end
  if vim.fn.isdirectory(vault .. "/journals") == 1 then table.insert(search_dirs, vault .. "/journals") end
  if #search_dirs == 0 then return on_complete({}) end

  local norm_exclude = exclude_file and util.normalize(exclude_file) or nil
  local needles   = build_needles(page_name)
  local uv        = vim.uv or vim.loop
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
        process_file(filepath, norm, page_name, needles, uv, results)
      end
    end

    if on_progress then on_progress(chunk_end, #all_files) end

    if chunk_end < #all_files then
      i = chunk_end + 1
      vim.schedule(process_chunk)
    else
      table.sort(results, function(a, b) return a.source_page < b.source_page end)
      on_complete(results)
    end
  end

  process_chunk()
end

return M
