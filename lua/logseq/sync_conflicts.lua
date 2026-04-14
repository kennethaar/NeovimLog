--- logseq.nvim Syncthing conflict resolution
--- Scans for .sync-conflict-* files and resolves them automatically.
--- Identical or mergeable conflicts are handled silently (append + dedup).
--- Extreme divergence (< 30% shared lines) is flagged for manual review.
--- Originals are always backed up to vault/deduped/ before modification.

local M = {}

local dedup = require("logseq.dedup")

--- Syncthing conflict filename pattern: .sync-conflict-YYYYMMDD-HHMMSS-XXXXXXX
local CONFLICT_SUFFIX = "%.sync%-conflict%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%w+"

--- Atomic write: temp file + rename to prevent partial writes.
local function atomic_write(path, content)
  local tmp = path .. ".synctmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  local ok = pcall(function() f:write(content) end)
  f:close()
  if not ok then os.remove(tmp) return false end
  local renamed = vim.uv.fs_rename(tmp, path)
  if not renamed then os.remove(tmp) return false end
  return true
end

--- Check whether two files share enough lines to auto-merge.
--- Tests both directions so pure appends (common case) aren't flagged.
local function is_mergeable(a, b)
  local set_a, set_b = {}, {}
  for line in a:gmatch("[^\n]+") do set_a[line] = true end
  for line in b:gmatch("[^\n]+") do set_b[line] = true end
  local function ratio(content, ref)
    local total, shared = 0, 0
    for line in content:gmatch("[^\n]+") do
      total = total + 1
      if ref[line] then shared = shared + 1 end
    end
    return total == 0 and 1 or shared / total
  end
  return math.max(ratio(b, set_a), ratio(a, set_b)) >= 0.3
end

--- Concatenate two file contents and run dedup to remove duplicate blocks.
local function merge_and_dedup(orig_content, conf_content)
  local lines = vim.split(orig_content, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  local conf_lines = vim.split(conf_content, "\n", { plain = true })
  if conf_lines[#conf_lines] == "" then table.remove(conf_lines) end
  vim.list_extend(lines, conf_lines)
  local cleaned = dedup.dedup_lines(lines)
  return table.concat(cleaned, "\n") .. "\n"
end

--- Resolve a single conflict file automatically.
--- Returns: "identical", "adopted", "gone", "merged", or "diverged"
function M.auto_resolve_one(conflict_path, original_path, vault)
  local orig = dedup.read_file(original_path)
  local conf = dedup.read_file(conflict_path)

  if not orig then
    if conf then vim.uv.fs_rename(conflict_path, original_path) end
    return "adopted"
  end
  
  if not conf then return "gone" end
  
  if orig == conf then
    os.remove(conflict_path)
    return "identical"
  end
  
  if not is_mergeable(orig, conf) then 
    return "diverged" 
  end

  dedup.backup_file(original_path, vault, orig)
  dedup.backup_file(conflict_path, vault, conf)
  
  -- If write succeeds, cleanly delete the conflict file
  if atomic_write(original_path, merge_and_dedup(orig, conf)) then
    os.remove(conflict_path)
  end
  
  return "merged"
end

--- Scan pages/ and journals/ for Syncthing conflict files.
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

--- Scan and auto-resolve all Syncthing conflicts.
function M.resolve_all(vault)
  local conflicts = M.scan_conflicts(vault)
  if #conflicts == 0 then return end

  local resolved, manual = 0, {}
  for _, c in ipairs(conflicts) do
    local outcome = M.auto_resolve_one(c.conflict, c.original, vault)
    if outcome == "diverged" then manual[#manual + 1] = vim.fn.fnamemodify(c.original, ":t")
    elseif outcome ~= "gone" then resolved = resolved + 1 end
  end

  -- Let autoread pick up any changed files
  pcall(function() vim.cmd("checktime") end)

  if resolved > 0 then
    vim.notify(("[logseq.nvim] Resolved %d Syncthing conflict(s)."):format(resolved), vim.log.levels.INFO)
  end
  if #manual > 0 then
    vim.notify("[logseq.nvim] Manual review needed: " .. table.concat(manual, ", "), vim.log.levels.WARN)
  end
end

return M