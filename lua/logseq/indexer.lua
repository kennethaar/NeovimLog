local M = {}
local a = require("plenary.async")
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

function M.find_backlinks(page_name, exclude_file, on_complete)
  local vault = config.current.vault_path
  if not vault then return on_complete({}) end

  a.void(function()
    a.util.scheduler()
    local files = vim.iter(util.get_vault_files(vault)):filter(function(f) return util.normalize(f) ~= util.normalize(exclude_file) end):totable()
    local results, batch_size = {}, 20
    for i = 1, #files, batch_size do
      local batch = vim.list_slice(files, i, math.min(i + batch_size - 1, #files))
      local thunks = vim.iter(batch):map(function(f)
        return function()
          local content = vim.fn.readfile(f)
          if not vim.iter(content):any(function(l) return l:lower():find(page_name:lower(), 1, true) end) then return end
          local lines, parsed = M.get_parsed_file(f)
          if parsed then return { file = f, source_page = M.page_name_from_file(f) } end
        end
      end):totable()
      vim.iter(a.util.join(thunks)):filter(function(r) return r ~= nil end):each(function(r) table.insert(results, r) end)
      a.util.sleep(5)
    end
    a.util.scheduler()
    on_complete(results)
  end)()
end

function M.find_scheduled_blocks(today_iso, on_complete) on_complete({ overdue = {}, upcoming = {} }) end

return M
