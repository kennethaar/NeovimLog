local M = {}
local parser = require("logseq.parser")
local util = require("logseq.util")
local config = require("logseq.config")

M._cache = {}
function M.invalidate(filepath) M._cache[util.normalize(filepath)] = nil end
function M.invalidate_all() M._cache = {} end

-- Safe fallback for getting vault files
local function get_vault_files_safe(vault_path)
  if type(util.get_vault_files) == "function" then
    return util.get_vault_files(vault_path)
  end
  local files = {}
  for _, dir in ipairs({ "pages", "journals" }) do
    local dir_path = vault_path .. "/" .. dir
    if vim.fn.isdirectory(dir_path) == 1 then
      local globbed = vim.fn.glob(dir_path .. "/*.md", false, true)
      if type(globbed) == "table" then
        vim.list_extend(files, globbed)
      end
    end
  end
  return files
end

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
  local uv = vim.uv or vim.loop
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

local function block_scheduled_date(block)
  for _, link in ipairs(block.links or {}) do
    if link:match("^%d%d%d%d%-%d%d%-%d%d$") then return link end
  end
end

local function block_todo_state(content)
  if not content then return nil end
  for _, s in ipairs(util.todo_states) do
    if content:sub(1, #s + 1) == s .. " " or content == s then return s end
  end
end

--- Recursive check to see if a block has any descendants that are also TODOs.
--- This is the core logic for the "Very Next Action" (VNA) filter.
local function has_todo_descendant(block)
  for _, child in ipairs(block.children or {}) do
    if block_todo_state(child.content) then
      return true
    end
    if has_todo_descendant(child) then
      return true
    end
  end
  return false
end

local function build_context_blocks(block)
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

--- Processes a list of files in batches to keep UI responsive.
local function process_file_list_batched(files, on_file, on_complete, on_progress)
  local i, BATCH = 0, 20
  local function step()
    for _ = 1, BATCH do
      i = i + 1
      if i > #files then
        if on_progress then on_progress(#files, #files) end
        on_complete()
        return
      end
      on_file(files[i], i)
    end
    if on_progress then on_progress(i, #files) end
    vim.schedule(step)
  end
  vim.schedule(step)
end

function M.find_backlinks(page_name, exclude_file, on_complete, on_progress)
  local vault = config.current.vault_path
  if not vault then return vim.schedule(function() on_complete({}) end) end

  local page_lower = page_name:lower()
  local results = {}

  local function process_file(f)
    local _, parsed = M.get_parsed_file(f)
    if not parsed then return end
    local source_page = M.page_name_from_file(f)
    for _, block in ipairs(parser.flatten(parsed.blocks)) do
      local linked = false
      for _, link in ipairs(block.links or {}) do
        if link:lower() == page_lower then linked = true; break end
      end
      if linked then
        local ctx = build_context_blocks(block)
        if ctx[#ctx] then ctx[#ctx].is_match = true end
        table.insert(results, {
          source_page       = source_page,
          source_file       = f,
          context_blocks    = ctx,
          todo_state        = block_todo_state(block.content),
          tags              = block.tags or {},
          is_scheduled      = block.is_scheduled or false,
          has_todo_children = has_todo_descendant(block),
        })
      end
    end
  end

  if vim.fn.executable("rg") == 1 then
    local rg_cmd = {
      "rg", "-l", "-i", "--fixed-strings", page_name,
      vault .. "/pages", vault .. "/journals"
    }

    vim.system(rg_cmd, { text = true }, function(obj)
      local matched_files = {}
      if obj.code == 0 and obj.stdout then
        for s in obj.stdout:gmatch("[^\r\n]+") do
          if util.normalize(s) ~= util.normalize(exclude_file) then
            table.insert(matched_files, s)
          end
        end
      end
      vim.schedule(function()
        process_file_list_batched(matched_files, process_file, function() on_complete(results) end, on_progress)
      end)
    end)
    return
  end

  -- Fallback
  local all_files = get_vault_files_safe(vault)
  local files = vim.tbl_filter(function(f) return util.normalize(f) ~= util.normalize(exclude_file) end, all_files)
  process_file_list_batched(files, process_file, function() on_complete(results) end, on_progress)
end

function M.find_scheduled_blocks(today_iso, on_complete)
  local vault = config.current.vault_path
  if not vault or vault == "" then
    return vim.schedule(function() on_complete({ overdue = {}, upcoming = {} }) end)
  end

  local overdue, upcoming = {}, {}

  local function process_file(fpath)
    local _, parsed = M.get_parsed_file(fpath)
    if not parsed then return end
    local source_page = M.page_name_from_file(fpath) or vim.fn.fnamemodify(fpath, ":t:r")
    for _, block in ipairs(parser.flatten(parsed.blocks)) do
      if block.is_scheduled then
        local date = block_scheduled_date(block)
        if date then
          local entry = {
            source_page       = source_page,
            source_file       = fpath,
            todo_state        = block_todo_state(block.content),
            tags              = block.tags or {},
            date              = date,
            context_blocks    = build_context_blocks(block),
            has_todo_children = has_todo_descendant(block),
          }
          if date < today_iso then table.insert(overdue, entry)
          else table.insert(upcoming, entry) end
        end
      end
    end
  end

  local function finalize()
    local by_date = function(x, y) return x.date < y.date end
    table.sort(overdue, by_date)
    table.sort(upcoming, by_date)
    on_complete({ overdue = overdue, upcoming = upcoming })
  end

  -- Optimized Search for Scheduled Blocks
  if vim.fn.executable("rg") == 1 then
    local rg_cmd = {
      "rg", "-l", "-e", "SCHEDULED:", "-e", "DEADLINE:",
      vault .. "/pages", vault .. "/journals"
    }
    vim.system(rg_cmd, { text = true }, function(obj)
      local matched = {}
      if obj.code == 0 and obj.stdout then
        for s in obj.stdout:gmatch("[^\r\n]+") do table.insert(matched, s) end
      end
      vim.schedule(function() process_file_list_batched(matched, process_file, finalize) end)
    end)
    return
  end

  local files = get_vault_files_safe(vault)
  process_file_list_batched(files, process_file, finalize)
end

return M