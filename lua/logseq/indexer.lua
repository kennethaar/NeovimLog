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
  if page_name then return util.decode_filename(page_name .. ".md") end

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

local function list_md_files(dirs)
  local files = {}
  for _, dir in ipairs(dirs) do
    vim.list_extend(files, vim.fn.glob(dir .. "/*.md", true, true))
  end
  return files
end

local function is_dominated(block, ancestor_lines)
  local cur = block.parent
  while cur do
    if ancestor_lines[cur.line_start] then return true end
    cur = cur.parent
  end
  return false
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
  local pages_dir = vault .. "/pages"
  local journals_dir = vault .. "/journals"
  if vim.fn.isdirectory(pages_dir) == 1 then table.insert(search_dirs, pages_dir) end
  if vim.fn.isdirectory(journals_dir) == 1 then table.insert(search_dirs, journals_dir) end
  if #search_dirs == 0 then return on_complete({}) end

  local norm_exclude = exclude_file and util.normalize(exclude_file) or nil
  local needles = build_needles(page_name)
  local all_files = list_md_files(search_dirs)
  local results = {}

  if #all_files == 0 then return on_complete({}) end

  local i = 1
  local uv = vim.uv or vim.loop

  local function process_chunk()
    local chunk_size = 50
    local chunk_end = math.min(i + chunk_size - 1, #all_files)

    for j = i, chunk_end do
      local filepath = all_files[j]
      local norm = util.normalize(filepath)
      if norm == norm_exclude then goto next_file end

      local stat = uv.fs_stat(filepath)
      local mtime = stat and stat.mtime.sec or 0
      local cached = M._cache[norm]
      local file_content, file_lines, parsed

      if cached and cached.mtime == mtime then
        if not content_matches(cached.content, needles) then goto next_file end
        file_lines = cached.lines
        parsed = cached.parsed
      else
        local f = io.open(filepath, "r")
        if not f then goto next_file end
        file_content = f:read("*a")
        f:close()

        if not content_matches(file_content, needles) then goto next_file end

        file_lines = vim.split(file_content, "\n", { plain = true })
        if #file_lines > 0 and file_lines[#file_lines] == "" then table.remove(file_lines) end

        parsed = parser.parse(file_lines)
        -- Cache: store parsed data for reuse. Parent refs create cycles but
        -- Lua's GC handles them. Cache is cleared on invalidate/invalidate_all.
        M._cache[norm] = { mtime = mtime, parsed = parsed, lines = file_lines, content = file_content }
      end

      local source_page = M.page_name_from_file(filepath) or vim.fn.fnamemodify(filepath, ":t:r")
      if source_page == page_name then goto next_file end

      local flat = parser.flatten(parsed.blocks)
      local all_refs = compute_all_refs(flat, source_page)
      local matching_blocks = {}
      local matched_lines = {}

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

    if on_progress then
      on_progress(chunk_end, #all_files)
    end

    if chunk_end < #all_files then
      i = chunk_end + 1
      vim.defer_fn(process_chunk, 5)
    else
      table.sort(results, function(a, b) return a.source_page < b.source_page end)
      on_complete(results)
    end
  end

  process_chunk()
end

return M
