--- logseq.nvim dedup
--- Remove exact duplicate lines from pages and journals.
--- Empty lines and "---" dividers are always preserved.
--- Originals are backed up to vault/deduped/ before any modification.

local M = {}

--- Remove exact duplicate lines from a list of lines.
--- Empty lines ("") and "---" section dividers are never considered duplicates.
--- Returns: cleaned lines (table), removed count (number)
function M.dedup_lines(lines)
  local seen = {}
  local result = {}
  local removed = 0

  for _, line in ipairs(lines) do
    if line == "" or line == "---" then
      result[#result + 1] = line
    elseif seen[line] then
      removed = removed + 1
    else
      seen[line] = true
      result[#result + 1] = line
    end
  end

  return result, removed
end

--- Copy content to vault/deduped/<stem>_<YYYY-MM-DD_HHMMSS>.<ext>.
--- Silently skips if the backup directory cannot be created or written.
local function backup_file(filepath, vault, content)
  local backup_dir = vault .. "/deduped"
  if vim.fn.isdirectory(backup_dir) == 0 then
    vim.fn.mkdir(backup_dir, "p")
  end
  local stem = vim.fn.fnamemodify(filepath, ":t:r")
  local ext  = vim.fn.fnamemodify(filepath, ":e")
  local ts   = os.date("%Y-%m-%d_%H%M%S")
  local dest = backup_dir .. "/" .. stem .. "_" .. ts .. "." .. ext
  local f = io.open(dest, "w")
  if not f then return end
  f:write(content)
  f:close()
end

--- Dedup the given buffer in-place. Shows a notification with the result.
--- bufnr defaults to the current buffer.
--- The original is backed up to vault/deduped/ before changes are applied.
--- Note: the entire operation is one undo entry — pressing u restores all
--- removed lines at once.
function M.dedup_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local new_lines, removed = M.dedup_lines(lines)

  if removed == 0 then
    vim.notify("[logseq.nvim] No duplicate lines found.", vim.log.levels.INFO)
    return
  end

  local vault = require("logseq.config").current.vault_path
  if vault and vault ~= "" then
    backup_file(vim.api.nvim_buf_get_name(bufnr), vault, table.concat(lines, "\n") .. "\n")
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
  vim.notify(("[logseq.nvim] Removed %d duplicate line(s)."):format(removed), vim.log.levels.INFO)
end

--- Dedup an open buffer silently, back up the original, and save.
--- Returns removed count.
local function dedup_open_buf(bufnr, vault)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local new_lines, removed = M.dedup_lines(lines)
  if removed > 0 then
    backup_file(vim.api.nvim_buf_get_name(bufnr), vault, table.concat(lines, "\n") .. "\n")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent write") end)
  end
  return removed
end

--- Dedup a file on disk (not open in a buffer), backing up the original first.
--- Returns removed count, or nil on read/write error.
local function dedup_file_on_disk(path, vault)
  local f = io.open(path, "r")
  if not f then return nil end
  local ok, content = pcall(function() return f:read("*a") end)
  f:close()
  if not ok then return nil end

  local lines = vim.split(content, "\n", { plain = true })
  -- vim.split on "a\nb\n" produces {"a","b",""} — drop the trailing empty
  if lines[#lines] == "" then table.remove(lines) end

  local new_lines, removed = M.dedup_lines(lines)
  if removed == 0 then return 0 end

  backup_file(path, vault, content)

  local wf = io.open(path, "w")
  if not wf then return nil end
  wf:write(table.concat(new_lines, "\n") .. "\n")
  wf:close()
  return removed
end

--- Dedup all .md files across the vault's pages/ and journals/ directories.
--- Files currently open in a buffer are deduped in-memory (and saved).
--- Files not open are deduped directly on disk.
--- Originals are backed up to vault/deduped/ before modification.
--- Processes files in batches to keep the UI responsive.
--- Shows a final summary notification when done.
function M.dedup_vault(vault)
  local files = {}
  for _, dir in ipairs({ vault .. "/pages", vault .. "/journals" }) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.list_extend(files, vim.fn.glob(dir .. "/*.md", false, true))
    end
  end

  local total_files, total_removed = 0, 0
  local i = 0
  local BATCH = 20

  local function step()
    for _ = 1, BATCH do
      i = i + 1
      if i > #files then
        vim.notify(
          ("[logseq.nvim] Vault dedup: removed %d duplicate line(s) from %d file(s).")
            :format(total_removed, total_files),
          vim.log.levels.INFO)
        return
      end

      local fpath = files[i]
      local bufnr = vim.fn.bufnr(fpath)
      local is_open = bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr)
      local removed = is_open and dedup_open_buf(bufnr, vault) or dedup_file_on_disk(fpath, vault)

      if removed == nil then
        vim.notify("[logseq.nvim] Dedup failed (write error): " .. fpath, vim.log.levels.WARN)
      elseif removed > 0 then
        total_files = total_files + 1
        total_removed = total_removed + removed
      end
    end
    vim.schedule(step)
  end
  vim.schedule(step)
end

return M
