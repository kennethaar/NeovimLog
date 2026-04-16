local M = {}
local parser = require("logseq.parser")
local util = require("logseq.util")
local config = require("logseq.config")

M._cache = {}
function M.invalidate(filepath) M._cache[util.normalize(filepath)] = nil end
function M.invalidate_all() M._cache = {} end

function M.page_name_from_file(filepath)
  local vault = config.current.vault_path
  if not vault or vault == "" then return nil end
  local norm_vault, norm_file = util.normalize(vault), util.normalize(filepath)
  if norm_file:sub(1, #norm_vault + 1) ~= norm_vault .. "/" then return nil end
  local rel = norm_file:sub(#norm_vault + 2)
  local journal_name = rel:match("^journals/(.+)%.md$")
  if journal_name then return util.format_journal_date(journal_name, vault) or journal_name end
  local page_name = rel:match("^pages/(.+)%.md$")
  return page_name and util.decode_filename(page_name) or nil
end

function M.get_parsed_file(filepath)
  local uv = vim.uv
  local norm = util.normalize(filepath)
  local stat = uv.fs_stat(filepath)
  if not stat then return nil, nil end
  local cached = M._cache[norm]
  if cached and cached.mtime == stat.mtime.sec then return cached.lines, cached.parsed end
  local fd = uv.fs_open(filepath, "r", 438)
  if not fd then return nil, nil end
  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not content then return nil, nil end
  local lines = vim.split(content, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  local parsed = parser.parse(lines)
  M._cache[norm] = { mtime = stat.mtime.sec, parsed = parsed, lines = lines, content = content }
  return lines, parsed
end

-- Extract the first ISO scheduled/deadline date referenced by a block.
-- The parser already appends `<YYYY-MM-DD …>` org-dates into block.links for
-- both the bullet content and every property/continuation line, so the whole
-- date search collapses to: return the first link that looks like an ISO date.
local function block_scheduled_date(block)
  for _, link in ipairs(block.links or {}) do
    if link:match("^%d%d%d%d%-%d%d%-%d%d$") then return link end
  end
end

local function block_todo_state(content)
  for _, s in ipairs(util.todo_states) do
    if content:sub(1, #s + 1) == s .. " " or content == s then return s end
  end
end

local function build_context_blocks(block)
  -- Walk ancestors to collect the outer → inner chain, then append the block
  -- itself as the non-ancestor leaf.
  local chain = {}
  local cur = block.parent
  while cur do
    table.insert(chain, 1, cur)
    cur = cur.parent
  end
  local ctx = {}
  for _, anc in ipairs(chain) do
    ctx[#ctx + 1] = {
      is_ancestor = true,
      indent      = anc.indent,
      text        = anc.content,
      source_line = anc.line_start,
    }
  end
  ctx[#ctx + 1] = {
    is_ancestor = false,
    indent      = block.indent,
    text        = block.content,
    source_line = block.line_start,
  }
  return ctx
end

function M.find_backlinks(page_name, exclude_file, on_complete, on_progress)
  local vault = config.current.vault_path
  if not vault then return vim.schedule(function() on_complete({}) end) end

  local files = vim.iter(util.get_vault_files(vault)):filter(function(f)
    return util.normalize(f) ~= util.normalize(exclude_file)
  end):totable()

  local results = {}
  local i, BATCH = 0, 20
  local page_lower = page_name:lower()

  local function step()
    for _ = 1, BATCH do
      i = i + 1
      if i > #files then
        if on_progress then on_progress(#files, #files) end
        on_complete(results)
        return
      end
      local f = files[i]
      local raw_lines = vim.fn.readfile(f)
      -- Quick pre-filter: skip files that don't mention the page at all.
      local mentions = false
      for _, l in ipairs(raw_lines) do
        if l:lower():find(page_lower, 1, true) then mentions = true; break end
      end
      if mentions then
        local _, parsed = M.get_parsed_file(f)
        if parsed then
          local source_page = M.page_name_from_file(f)
          for _, block in ipairs(parser.flatten(parsed.blocks)) do
            local linked = false
            for _, link in ipairs(block.links or {}) do
              if link:lower() == page_lower then linked = true; break end
            end
            if linked then
              local ctx = build_context_blocks(block)
              -- Mark the leaf (the matching block itself) as the match
              if ctx[#ctx] then ctx[#ctx].is_match = true end
              table.insert(results, {
                source_page       = source_page,
                source_file       = f,
                context_blocks    = ctx,
                todo_state        = block_todo_state(block.content),
                tags              = block.tags or {},
                is_scheduled      = block.is_scheduled or false,
                has_todo_children = false,
              })
            end
          end
        end
      end
      if on_progress then on_progress(i, #files) end
    end
    vim.schedule(step)
  end
  vim.schedule(step)
end

function M.find_scheduled_blocks(today_iso, on_complete)
  local vault = config.current.vault_path
  if not vault or vault == "" then
    return vim.schedule(function() on_complete({ overdue = {}, upcoming = {} }) end)
  end

  local files = util.get_vault_files(vault)
  local overdue, upcoming = {}, {}
  local i, BATCH = 0, 20

  local function step()
    for _ = 1, BATCH do
      i = i + 1
      if i > #files then
        local by_date = function(x, y) return x.date < y.date end
        table.sort(overdue, by_date)
        table.sort(upcoming, by_date)
        on_complete({ overdue = overdue, upcoming = upcoming })
        return
      end
      local fpath = files[i]
      local _, parsed = M.get_parsed_file(fpath)
      if parsed then
        local source_page = M.page_name_from_file(fpath) or vim.fn.fnamemodify(fpath, ":t:r")
        for _, block in ipairs(parser.flatten(parsed.blocks)) do
          if block.is_scheduled then
            local date = block_scheduled_date(block)
            if date then
              local entry = {
                source_page    = source_page,
                source_file    = fpath,
                todo_state     = block_todo_state(block.content),
                tags           = block.tags or {},
                date           = date,
                context_blocks = build_context_blocks(block),
              }
              if date < today_iso then table.insert(overdue, entry)
              else table.insert(upcoming, entry) end
            end
          end
        end
      end
    end
    vim.schedule(step)
  end
  vim.schedule(step)
end

return M
