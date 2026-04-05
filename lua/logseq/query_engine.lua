--- logseq.nvim query engine
--- Async vault scanner. Evaluates a query AST predicate against every block
--- in the vault and returns matching results.
---
--- Reuses indexer._cache so already-parsed files are served at zero I/O cost.

local config  = require("logseq.config")
local indexer = require("logseq.indexer")
local parser  = require("logseq.parser")
local util    = require("logseq.util")

local M = {}

-- ── Block helpers ──────────────────────────────────────────────────────

local function get_todo_state(content)
  for _, state in ipairs(util.todo_states) do
    local prefix = state .. " "
    local upper  = content:upper()
    if upper:sub(1, #prefix) == prefix or upper == state then return state end
  end
end

--- Walk up the parent chain to find the nearest TODO state.
local function effective_todo(block)
  local cur = block
  while cur do
    local s = get_todo_state(cur.content)
    if s then return s end
    cur = cur.parent
  end
end

--- Collect tags from the block and all its ancestors (Logseq tag inheritance).
local function effective_tags(block)
  local tags, seen = {}, {}
  local cur = block
  while cur do
    for _, tag in ipairs(cur.tags) do
      if not seen[tag] then seen[tag] = true; tags[#tags + 1] = tag end
    end
    cur = cur.parent
  end
  return tags
end

--- True if the block (or any ancestor) links to page_lower or any of its
--- namespace children (page_lower + "/" prefix).
local function block_links_page(block, page_lower)
  local ns_prefix = page_lower .. "/"
  local cur = block
  while cur do
    for _, link in ipairs(cur.links) do
      local ll = link:lower()
      if ll == page_lower or ll:sub(1, #ns_prefix) == ns_prefix then return true end
    end
    cur = cur.parent
  end
  return false
end

-- ── Predicate evaluators (table-dispatched) ────────────────────────────

local eval  -- forward declaration

local evaluators = {}

evaluators["page_link"] = function(ast, block, ctx)
  -- "current page" is a dynamic placeholder resolved at run-time.
  local page = ast.page:lower() == "current page"
    and (ctx.current_page or ""):lower()
    or   ast.page:lower()
  return page ~= "" and block_links_page(block, page)
end

evaluators["todo"] = function(ast, _block, ctx)
  if not ctx.todo_state then return false end
  for _, s in ipairs(ast.states) do
    if s == ctx.todo_state then return true end
  end
  return false
end

evaluators["task"] = evaluators["todo"]

evaluators["tags"] = function(ast, _block, ctx)
  -- Block must carry ALL of the required tags.
  local tag_set = {}
  for _, t in ipairs(ctx.tags) do tag_set[t:lower()] = true end
  for _, required in ipairs(ast.tags) do
    if not tag_set[required:lower()] then return false end
  end
  return #ast.tags > 0
end

evaluators["property"] = function(ast, block, _ctx)
  local val = util.prop_ci(block.properties, ast.key:lower())
  if not val then return false end
  if not ast.value then return true end           -- property exists
  return val:lower() == ast.value:lower()
end

evaluators["page_property"] = function(ast, _block, ctx)
  local val = util.prop_ci(ctx.page_props, ast.key:lower())
  if not val then return false end
  if not ast.value then return true end
  return val:lower() == ast.value:lower()
end

evaluators["between"] = function(ast, _block, ctx)
  if not ctx.journal_date then return false end
  return ctx.journal_date >= ast.from and ctx.journal_date <= ast.to
end

evaluators["and"] = function(ast, block, ctx)
  for _, child in ipairs(ast.children) do
    if not eval(child, block, ctx) then return false end
  end
  return true
end

evaluators["or"] = function(ast, block, ctx)
  for _, child in ipairs(ast.children) do
    if eval(child, block, ctx) then return true end
  end
  return false
end

evaluators["not"] = function(ast, block, ctx)
  return not eval(ast.children[1], block, ctx)
end

eval = function(ast, block, ctx)
  if not ast then return false end
  local fn = evaluators[ast.type]
  return fn and fn(ast, block, ctx) or false
end

-- ── File I/O ───────────────────────────────────────────────────────────

--- Return ISO journal date "YYYY-MM-DD" for a journals/*.md filepath, or nil.
local function journal_date(filepath)
  local stem = filepath:match("[/\\]journals[/\\](.+)%.md$")
  if not stem then return nil end
  local y, m, d = stem:match("^(%d%d%d%d)[_%-](%d%d)[_%-](%d%d)")
  return y and (y .. "-" .. m .. "-" .. d) or nil
end

--- Load a file from the indexer cache or fresh from disk.
--- Returns file_lines, parsed — or nil, nil on failure.
local function load_file(filepath, uv)
  local norm = util.normalize(filepath)
  local stat = uv.fs_stat(filepath)
  if not stat then return nil, nil end

  local cached = indexer._cache[norm]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.lines, cached.parsed
  end

  local fd = uv.fs_open(filepath, "r", 438)
  if not fd then return nil, nil end
  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not content then return nil, nil end

  local lines = vim.split(content, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  local parsed = parser.parse(lines)
  indexer._cache[norm] = { mtime = stat.mtime.sec, parsed = parsed, lines = lines, content = content }
  return lines, parsed
end

--- Scan one file and append any matching blocks to results.
local function process_file(filepath, ast, opts, uv, results)
  local _lines, parsed = load_file(filepath, uv)
  if not parsed then return end

  local source_page = indexer.page_name_from_file(filepath)
                   or vim.fn.fnamemodify(filepath, ":t:r")
  local jdate       = journal_date(filepath)
  local page_props  = parsed.page_properties

  for _, block in ipairs(parser.flatten(parsed.blocks)) do
    local ctx = {
      todo_state    = effective_todo(block),
      tags          = effective_tags(block),
      journal_date  = jdate,
      page_props    = page_props,
      current_page  = opts.current_page,
    }
    if eval(ast, block, ctx) then
      results[#results + 1] = {
        source_page = source_page,
        source_file = filepath,
        content     = block.content,
        line_start  = block.line_start,
        todo_state  = ctx.todo_state,
        tags        = ctx.tags,
        date        = jdate,
        properties  = block.properties,
      }
    end
  end
end

-- ── Public API ─────────────────────────────────────────────────────────

--- Async: evaluate ast against every block in the vault.
--- Calls on_complete(results[]) when done.
--- Reuses the indexer's file cache so repeated queries are fast.
---@param ast         table
---@param opts        table   { current_page: string|nil }
---@param on_complete function
function M.run(ast, opts, on_complete)
  local raw_vault = config.current.vault_path
  if not raw_vault or raw_vault == "" then
    return vim.schedule(function() on_complete({}) end)
  end
  local vault = util.normalize(raw_vault)

  local search_dirs = {}
  if vim.fn.isdirectory(vault .. "/pages")   == 1 then
    search_dirs[#search_dirs + 1] = vault .. "/pages"
  end
  if vim.fn.isdirectory(vault .. "/journals") == 1 then
    search_dirs[#search_dirs + 1] = vault .. "/journals"
  end
  if #search_dirs == 0 then
    return vim.schedule(function() on_complete({}) end)
  end

  local uv = vim.uv or vim.loop

  local all_files = {}
  for _, dir in ipairs(search_dirs) do
    local handle = uv.fs_scandir(dir)
    if handle then
      while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then break end
        if name:sub(-3) == ".md" and ftype ~= "directory" then
          all_files[#all_files + 1] = dir .. "/" .. name
        end
      end
    end
  end

  if #all_files == 0 then
    return vim.schedule(function() on_complete({}) end)
  end

  local results = {}
  local i = 1

  local function process_chunk()
    local chunk_end = math.min(i + 49, #all_files)
    for j = i, chunk_end do
      process_file(all_files[j], ast, opts, uv, results)
    end
    if chunk_end < #all_files then
      i = chunk_end + 1
      vim.schedule(process_chunk)
    else
      table.sort(results, function(a, b)
        if a.source_page ~= b.source_page then return a.source_page < b.source_page end
        return a.line_start < b.line_start
      end)
      on_complete(results)
    end
  end

  vim.schedule(process_chunk)
end

return M
