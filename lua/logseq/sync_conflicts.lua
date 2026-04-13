--- logseq.nvim Syncthing conflict resolution
local M = {}
local dedup = require("logseq.dedup")

local CONFLICT_SUFFIX = "%.sync%-conflict%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%w+"

local function atomic_write(path, content)
  local tmp = path .. ".synctmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  local ok = pcall(function() f:write(content) end)
  f:close()
  if not ok then os.remove(tmp) return false end
  return vim.uv.fs_rename(tmp, path)
end

local function is_mergeable(orig, conf)
  local orig_lines, orig_total, conf_total, shared = {}, 0, 0, 0
  for line in orig:gmatch("[^\n]+") do 
    orig_lines[line] = true 
    orig_total = orig_total + 1 
  end
  for line in conf:gmatch("[^\n]+") do
    conf_total = conf_total + 1
    if orig_lines[line] then shared = shared + 1 end
  end
  local max_ratio = math.max(
    orig_total > 0 and (shared / orig_total) or 1,
    conf_total > 0 and (shared / conf_total) or 1
  )
  return max_ratio >= 0.3
end

local function merge_and_dedup(orig, conf)
  local lines = vim.split(orig, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  local conf_lines = vim.split(conf, "\n", { plain = true })
  if conf_lines[#conf_lines] == "" then table.remove(conf_lines) end
  vim.list_extend(lines, conf_lines)
  local cleaned = dedup.dedup_lines(lines)
  return table.concat(cleaned, "\n") .. "\n"
end

function M.auto_resolve_one(conflict_path, original_path, vault)
  local orig = dedup.read_file(original_path)
  local conf = dedup.read_file(conflict_path)

  if not orig then return vim.uv.fs_rename(conflict_path, original_path) and "resolved" end
  if not conf then return "gone" end
  if orig == conf then os.remove(conflict_path); return "resolved" end
  if not is_mergeable(orig, conf) then return "diverged" end

  dedup.backup_file(original_path, vault, orig)
  dedup.backup_file(conflict_path, vault, conf)
  atomic_write(original_path, merge_and_dedup(orig, conf))
  os.remove(conflict_path)

  return "resolved"
end

function M.scan_conflicts(vault)
  if not vault or vault == "" then return {} end
  local results = {}
  for _, dir in ipairs({ vault .. "/pages", vault .. "/journals" }) do
    if vim.fn.isdirectory(dir) == 1 then
      for _, fpath in ipairs(vim.fn.glob(dir .. "/*.sync-conflict-*.md", false, true)) do
        local name = vim.fn.fnamemodify(fpath, ":t")
        if name:match(CONFLICT_SUFFIX) then
          results[#results + 1] = {
            conflict = fpath,
            original = vim.fn.fnamemodify(fpath, ":h") .. "/" .. name:gsub(CONFLICT_SUFFIX, ""),
          }
        end
      end
    end
  end
  return results
end

function M.resolve_all(vault)
  local conflicts = M.scan_conflicts(vault)
  if #conflicts == 0 then return end

  local resolved, diverged = 0, {}
  for _, c in ipairs(conflicts) do
    if M.auto_resolve_one(c.conflict, c.original, vault) == "resolved" then 
      resolved = resolved + 1
    else 
      diverged[#diverged + 1] = vim.fn.fnamemodify(c.original, ":t") 
    end
  end

  if resolved > 0 or #diverged > 0 then
    local msg = string.format("[logseq.nvim] Syncthing: %d conflicts auto-resolved.", resolved)
    if #diverged > 0 then msg = msg .. string.format(" %d require manual review: %s", #diverged, table.concat(diverged, ", ")) end
    vim.notify(msg, #diverged > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
    vim.cmd("checktime")
  end
end

return M