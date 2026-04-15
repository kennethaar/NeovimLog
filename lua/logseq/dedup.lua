local M = {}

local function line_indent(line)
  local _, j = line:find("^%s*")
  return j or 0
end

local function segment(lines, indent)
  local blocks, i, n = {}, 1, #lines
  while i <= n do
    local line = lines[i]
    local block = { line = line, body = {}, keep = (line == "" or line == "---") }
    i = i + 1
    if not block.keep then
      while i <= n and lines[i] ~= "" and line_indent(lines[i]) > indent do
        table.insert(block.body, lines[i])
        i = i + 1
      end
    end
    table.insert(blocks, block)
  end
  return blocks
end

local function flatten_blocks(blocks)
  local out = {}
  for _, b in ipairs(blocks) do
    out[#out + 1] = b.line
    vim.list_extend(out, b.body)
  end
  return out
end

local function dedup_block_list(lines, indent)
  local blocks = segment(lines, indent)
  local order, seen = {}, {}
  for _, block in ipairs(blocks) do
    if block.keep then table.insert(order, block)
    elseif seen[block.line] then vim.list_extend(seen[block.line].body, block.body)
    else seen[block.line] = block; table.insert(order, block) end
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

function M.dedup_lines(lines)
  local result = flatten_blocks(dedup_block_list(lines, 0))
  return result, #lines - #result
end

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local ok, content = pcall(function() return f:read("*a") end)
  f:close()
  return ok and content or nil
end

function M.backup_file(filepath, vault, content)
  local backup_dir = vim.fs.joinpath(vault, "deduped")
  vim.fn.mkdir(backup_dir, "p")
  local stem = vim.fn.fnamemodify(filepath, ":t:r")
  local ext  = vim.fn.fnamemodify(filepath, ":e")
  local ts   = os.date("%Y-%m-%d_%H%M%S")
  local dest = vim.fs.joinpath(backup_dir, stem .. "_" .. ts .. "." .. ext)
  local n = 1
  while vim.fn.filereadable(dest) == 1 do
    dest = vim.fs.joinpath(backup_dir, stem .. "_" .. ts .. "_" .. n .. "." .. ext)
    n = n + 1
  end
  local f = io.open(dest, "wb")
  if not f then return end
  local ok = pcall(function() f:write(content) end)
  f:close()
  if not ok then os.remove(dest) end
end

M.dedup_buf = function(bufnr)
  local a = require("plenary.async")
  a.void(function()
    a.util.scheduler()
    bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local new_lines, removed = M.dedup_lines(lines)
    if removed == 0 then vim.notify("[logseq.nvim] No duplicate lines found.", vim.log.levels.INFO); return end

    local vault = require("logseq.config").current.vault_path
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if vault and filepath ~= "" then
      local uv = vim.uv
      local backup_dir = vim.fs.joinpath(vault, "deduped")
      vim.fn.mkdir(backup_dir, "p")
      local stem, ext = vim.fn.fnamemodify(filepath, ":t:r"), vim.fn.fnamemodify(filepath, ":e")
      local ts = os.date("%Y-%m-%d_%H%M%S")
      local dest = vim.fs.joinpath(backup_dir, string.format("%s_%s.%s", stem, ts, ext))
      local n = 1
      while uv.fs_stat(dest) do dest = vim.fs.joinpath(backup_dir, string.format("%s_%s_%d.%s", stem, ts, n, ext)); n = n + 1 end
      local fd = a.wrap(uv.fs_open, 4)(dest, "w", 438)
      if fd then a.wrap(uv.fs_write, 4)(fd, table.concat(lines, "\n") .. "\n", 0); uv.fs_close(fd) end
    end

    a.util.scheduler()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    vim.notify(("[logseq.nvim] Removed %d duplicate line(s)."):format(removed), vim.log.levels.INFO)
  end)()
end

M.dedup_vault = function(vault)
  local a = require("plenary.async")
  local uv = vim.uv
  local fs_open, fs_fstat, fs_read, fs_write, fs_rename = a.wrap(uv.fs_open, 4), a.wrap(uv.fs_fstat, 2), a.wrap(uv.fs_read, 4), a.wrap(uv.fs_write, 4), a.wrap(uv.fs_rename, 3)

  local function process_file_on_disk_async(path)
    local _, fd = fs_open(path, "r", 438)
    if not fd then return 0 end
    local _, stat = fs_fstat(fd)
    local _, content = fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    local lines = vim.split(content, "\n", { plain = true })
    if lines[#lines] == "" then table.remove(lines) end
    local new_lines, removed = M.dedup_lines(lines)
    if removed == 0 then return 0 end
    local tmp = path .. ".dedup_tmp"
    local _, wfd = fs_open(tmp, "w", 438)
    if wfd then
      fs_write(wfd, table.concat(new_lines, "\n") .. "\n", 0); uv.fs_close(wfd)
      if not fs_rename(tmp, path) then return removed end
      uv.fs_unlink(tmp)
    end
    return 0
  end

  a.void(function()
    a.util.scheduler()
    local files = require("logseq.util").get_vault_files(vault)
    local total_files, total_removed, batch_size = 0, 0, 20

    for i = 1, #files, batch_size do
      local batch = vim.list_slice(files, i, math.min(i + batch_size - 1, #files))
      local thunks = vim.iter(batch):map(function(fpath) return function() return (vim.fn.bufnr(fpath) == -1) and process_file_on_disk_async(fpath) or 0 end end):totable()
      local results = a.util.join(thunks)
      for _, rem in ipairs(results) do if rem > 0 then total_files, total_removed = total_files + 1, total_removed + rem end end
      a.util.sleep(5)
    end

    a.util.scheduler()
    if total_removed == 0 then vim.notify("[logseq.nvim] Vault dedup: no duplicates found.", vim.log.levels.INFO) else vim.notify(("[logseq.nvim] Vault dedup: removed %d lines from %d files."):format(total_removed, total_files)) end
  end)()
end

return M
