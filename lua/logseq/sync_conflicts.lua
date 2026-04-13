--- logseq.nvim Syncthing conflict resolution
--- Automatically scans for .sync-conflict-* files and resolves them.
--- Trivial cases (identical, subset) are cleaned up silently.
--- Non-trivial cases are auto-merged via append + dedup.
--- Extreme divergence (< 30% shared lines) is flagged for manual review.
--- Originals are always backed up to vault/deduped/ before modification.

local M = {}

--- Read a file from disk. Returns content string or nil.
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local ok, content = pcall(function() return f:read("*a") end)
  f:close()
  return ok and content or nil
end

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

--- Fraction of lines in content_b that also appear in content_a.
--- Returns 1.0 for empty content_b (nothing to diverge from).
local function shared_line_ratio(content_a, content_b)
  local set = {}
  for line in content_a:gmatch("[^\n]+") do set[line] = true end
  local total, shared = 0, 0
  for line in content_b:gmatch("[^\n]+") do
    total = total + 1
    if set[line] then shared = shared + 1 end
  end
  if total == 0 then return 1 end
  return shared / total
end

--- Concatenate two file contents and run dedup to remove duplicate blocks.
local function merge_and_dedup(orig_content, conf_content)
  local dedup = require("logseq.dedup")
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
  local orig = read_file(original_path)
  local conf = read_file(conflict_path)

  -- Original was deleted; adopt the conflict version
  if not orig then
    os.rename(conflict_path, original_path)
    return "adopted"
  end

  -- Conflict file disappeared between scan and resolve
  if not conf then return "gone" end

  -- Identical content — just clean up the conflict file
  if orig == conf then
    os.remove(conflict_path)
    return "identical"
  end

  -- Extreme divergence — flag for manual review, don't auto-merge
  if shared_line_ratio(orig, conf) < 0.3 then
    return "diverged"
  end

  -- Auto-merge: append + dedup (safe for Logseq bullet-point content)
  local dedup = require("logseq.dedup")
  dedup.backup_file(original_path, vault, orig)
  dedup.backup_file(conflict_path, vault, conf)
  local merged = merge_and_dedup(orig, conf)
  atomic_write(original_path, merged)
  os.remove(conflict_path)

  -- Reload buffer if open
  local bufnr = vim.fn.bufnr(original_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("edit!") end)
    local stat = vim.uv.fs_stat(original_path)
    if stat then vim.b[bufnr].logseq_mtime = stat.mtime.sec end
  end

  return "merged"
end

--- Scan pages/ and journals/ for Syncthing conflict files.
--- Returns list of { conflict = path, original = path }.
function M.scan_conflicts(vault)
  if not vault or vault == "" then return {} end
  local results = {}
  for _, dir in ipairs({ vault .. "/pages", vault .. "/journals" }) do
    if vim.fn.isdirectory(dir) == 1 then
      for _, fpath in ipairs(vim.fn.glob(dir .. "/*.sync-conflict-*.md", false, true)) do
        local name = vim.fn.fnamemodify(fpath, ":t")
        local orig_name = name:gsub("%.sync%-conflict%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%w+", "")
        results[#results + 1] = {
          conflict = fpath,
          original = vim.fn.fnamemodify(fpath, ":h") .. "/" .. orig_name,
        }
      end
    end
  end
  return results
end

--- Scan and auto-resolve all Syncthing conflicts. Shows a summary notification.
function M.resolve_all(vault)
  local conflicts = M.scan_conflicts(vault)
  if #conflicts == 0 then return end

  local merged, identical, adopted = 0, 0, 0
  local diverged = {}
  for _, c in ipairs(conflicts) do
    local outcome = M.auto_resolve_one(c.conflict, c.original, vault)
    if outcome == "merged" then merged = merged + 1
    elseif outcome == "identical" then identical = identical + 1
    elseif outcome == "adopted" then adopted = adopted + 1
    elseif outcome == "diverged" then diverged[#diverged + 1] = c end
  end

  local parts = {}
  if merged > 0 then parts[#parts + 1] = merged .. " merged" end
  if identical > 0 then parts[#parts + 1] = identical .. " identical (cleaned)" end
  if adopted > 0 then parts[#parts + 1] = adopted .. " adopted" end
  if #diverged > 0 then
    local names = {}
    for _, d in ipairs(diverged) do
      names[#names + 1] = vim.fn.fnamemodify(d.original, ":t")
    end
    parts[#parts + 1] = #diverged .. " need manual review: " .. table.concat(names, ", ")
  end

  if #parts == 0 then return end
  local level = #diverged > 0 and vim.log.levels.WARN or vim.log.levels.INFO
  vim.notify("[logseq.nvim] Syncthing conflicts: " .. table.concat(parts, ", "), level)
end

return M
