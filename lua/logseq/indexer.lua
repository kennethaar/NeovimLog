local M = {}
local util = require("logseq.util")
local parser = require("logseq.parser")
local config = require("logseq.config")
M._cache = {}

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
  local parsed = parser.parse(lines)
  M._cache[norm] = { mtime = stat.mtime.sec, parsed = parsed, lines = lines, content = content }
  return lines, parsed
end

function M.find_backlinks(page_name, exclude_file, on_complete, on_progress)
  local vault = config.current.vault_path
  if not vault then return on_complete({}) end
  local page_lower = page_name:lower()
  local results = {}
  local function process_file(f)
    local _, parsed = M.get_parsed_file(f)
    if not parsed then return end
    for _, block in ipairs(parser.flatten(parsed.blocks)) do
      for _, link in ipairs(block.links or {}) do
        if link:lower() == page_lower then
          table.insert(results, { source_file = f, text = block.content })
          break
        end
      end
    end
  end
  if vim.fn.executable("rg") == 1 then
    vim.system({"rg", "-l", "-i", "--fixed-strings", page_name, vault}, {text=true}, function(obj)
      local matched = {}
      if obj.code == 0 and obj.stdout then
        for s in obj.stdout:gmatch("[^\r\n]+") do table.insert(matched, s) end
      end
      vim.schedule(function() process_file_list_batched(matched, process_file, function() on_complete(results) end, on_progress) end)
    end)
  end
end
return M
