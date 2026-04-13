--- logseq.nvim dedup
--- Remove exact duplicate lines from pages and journals.
--- Empty lines and "---" dividers are always preserved.
--- Originals are backed up to vault/deduped/ before any modification.

local M = {}

--- Returns the number of leading spaces in a line.
local function line_indent(line)
  return #(line:match("^(%s*)"))
end

--- Segment a flat list of lines at a given indent level into blocks.
--- Each block = { line, body[], always_keep? }
--- Body collects all deeper-indented lines following the header, stopping
--- at the next empty line or a line at the same or lesser indent.
--- Empty lines and "---" dividers are always_keep blocks with no body.
local function segment(lines, indent)
  local blocks = {}
  local i, n = 1, #lines
  while i <= n do
    local line = lines[i]
    if line == "" or line == "---" then
      blocks[#blocks + 1] = { line = line, body = {}, always_keep = true }
      i = i + 1
    else
      local block = { line = line, body = {} }
      i = i + 1
      while i <= n do
        local next = lines[i]
        if next == "" or line_indent(next) <= indent then break end
        block.body[#block.body + 1] = next
        i = i + 1
      end
      blocks[#blocks + 1] = block
    end
  end
  return blocks
end

--- Flatten a list of blocks back into a flat list of lines.
local function flatten_blocks(blocks)
  local lines = {}
  for _, b in ipairs(blocks) do
    lines[#lines + 1] = b.line
    vim.list_extend(lines, b.body)
  end
  return lines
end

--- Recursively dedup a list of lines at a given indent level.
--- Duplicate block headers have their bodies appended to the first occurrence.
--- The merged body is then recursively deduped at the next indent level.
local function dedup_block_list(lines, indent)
  local blocks = segment(lines, indent)
  local order, seen = {}, {}

  for _, block in ipairs(blocks) do
    if block.always_keep then
      order[#order + 1] = block
    elseif seen[block.line] then
      vim.list_extend(seen[block.line].body, block.body)
    else
      local entry = { line = block.line, body = block.body }
      seen[block.line] = entry
      order[#order + 1] = entry
    end
  end

  for _, entry in ipairs(order) do
    if #entry.body > 0 then
      local child_indent = indent + 2
      for _, l in ipairs(entry.body) do
        if l ~= "" then child_indent = line_indent(l); break end
      end
      entry.body = flatten_blocks(dedup_block_list(entry.body, child_indent))
    end
  end

  return order
end

--- Remove exact duplicate lines from a list of lines, block-tree-aware.
--- Empty lines ("") and "---" section dividers are always preserved.
--- When two blocks share the same header line, the duplicate is removed and
--- its entire child subtree is appended to the children of the kept copy.
--- Duplicate children within the merged subtree are also removed recursively.
--- Returns: cleaned lines (table), removed count (number)
function M.dedup_lines(lines)
  local result = flatten_blocks(dedup_block_list(lines, 0))
  return result, #lines - #result
end

--- Read a file from disk. Returns content string or nil on any error.
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local ok, content = pcall(function() return f:read("*a") end)
  f:close()
  return ok and content or nil
end

--- Copy content to vault/deduped/<stem>_<YYYY-MM-DD_HHMMSS>[_N].<ext>.
--- Appends _1, _2, ... if a file with that timestamp already exists.
--- Silently skips if the directory cannot be created or the file cannot be written.
function M.backup_file(filepath, vault, content)
  local backup_dir = vault .. "/deduped"
  vim.fn.mkdir(backup_dir, "p")

  local stem = vim.fn.fnamemodify(filepath, ":t:r")
  local ext  = vim.fn.fnamemodify(filepath, ":e")
  local ts   = os.date("%Y-%m-%d_%H%M%S")
  local dest = backup_dir .. "/" .. stem .. "_" .. ts .. "." .. ext

  local n = 1
  while vim.fn.filereadable(dest) == 1 do
    dest = backup_dir .. "/" .. stem .. "_" .. ts .. "_" .. n .. "." .. ext
    n = n + 1
  end

  local f = io.open(dest, "wb")
  if not f then return end
  local write_ok = pcall(function() f:write(content) end)
  f:close()
  if not write_ok then os.remove(dest) end
end

--- Dedup the given buffer in-place. Shows a notification with the result.
--- bufnr defaults to the current buffer.
--- Backs up the disk version of the file before applying changes, preserving
--- original line endings. Falls back to buffer reconstruction for unsaved files.
--- Note: the entire operation is one undo entry — pressing u restores all
--- removed lines at once.
function M.dedup_buf(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local new_lines, removed = M.dedup_lines(lines)

  if removed == 0 then
    vim.notify("[logseq.nvim] No duplicate lines found.", vim.log.levels.INFO)
    return
  end

  local vault = require("logseq.config").current.vault_path
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if vault and vault ~= "" and filepath ~= "" then
    local content = read_file(filepath) or (table.concat(lines, "\n") .. "\n")
    M.backup_file(filepath, vault, content)
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
  vim.notify(("[logseq.nvim] Removed %d duplicate line(s)."):format(removed), vim.log.levels.INFO)
end

--- Dedup an open buffer silently, back up the disk version, and save.
--- Returns removed count, or nil on write error.
local function dedup_open_buf(bufnr, vault)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local new_lines, removed = M.dedup_lines(lines)
  if removed == 0 then return 0 end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local content = read_file(filepath) or (table.concat(lines, "\n") .. "\n")
  backup_file(filepath, vault, content)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
  local ok = pcall(function()
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent write") end)
  end)
  if not ok then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return nil
  end
  return removed
end

--- Dedup a file on disk (not open in a buffer), backing up the original first.
--- Uses an atomic write (temp file + rename) to protect against partial writes.
--- Returns removed count, or nil on read/write error.
local function dedup_file_on_disk(path, vault)
  local content = read_file(path)
  if not content then return nil end

  local lines = vim.split(content, "\n", { plain = true })
  -- vim.split on "a\nb\n" produces {"a","b",""} — drop the trailing empty
  if lines[#lines] == "" then table.remove(lines) end

  local new_lines, removed = M.dedup_lines(lines)
  if removed == 0 then return 0 end

  M.backup_file(path, vault, content)

  local tmp = path .. ".dedup_tmp"
  local wf = io.open(tmp, "wb")
  if not wf then return nil end
  local write_ok = pcall(function() wf:write(table.concat(new_lines, "\n") .. "\n") end)
  wf:close()
  if not write_ok then os.remove(tmp); return nil end
  local renamed = vim.uv.fs_rename(tmp, path)
  if not renamed then os.remove(tmp); return nil end

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
        if total_removed == 0 then
          vim.notify("[logseq.nvim] Vault dedup: no duplicates found.", vim.log.levels.INFO)
        else
          vim.notify(
            ("[logseq.nvim] Vault dedup: removed %d duplicate line(s) from %d file(s).")
              :format(total_removed, total_files),
            vim.log.levels.INFO)
        end
        return
      end

      local fpath = files[i]
      local bufnr = vim.fn.bufnr(fpath)
      local removed
      if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        removed = dedup_open_buf(bufnr, vault)
      else
        removed = dedup_file_on_disk(fpath, vault)
      end

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
