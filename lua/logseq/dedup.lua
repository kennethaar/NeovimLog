local M = {}

function M.read_file_async(path, callback)
  local uv = vim.uv or vim.loop
  uv.fs_open(path, "r", 438, function(err, fd)
    if err or not fd then return callback(nil) end
    uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or not stat then
        uv.fs_close(fd)
        return callback(nil)
      end
      uv.fs_read(fd, stat.size, 0, function(read_err, data)
        uv.fs_close(fd)
        callback(read_err and nil or data)
      end)
    end)
  end)
end

function M.safe_write_async(path, content, callback)
  local uv = vim.uv or vim.loop
  uv.fs_open(path, "w", 438, function(err, fd)
    if err or not fd then return callback(false) end
    uv.fs_write(fd, content, 0, function(write_err)
      uv.fs_close(fd)
      if callback then callback(write_err == nil) end
    end)
  end)
end

function M.backup_file_async(path, vault, content)
  local name = vim.fn.fnamemodify(path, ":t")
  local bdir = vault.. "/bak"
  if vim.fn.isdirectory(bdir) == 0 then vim.fn.mkdir(bdir, "p") end
  local bpath = bdir.. "/".. name.. ".".. os.date("%Y%m%d%H%M%S").. ".bak"
  M.safe_write_async(bpath, content, function() end)
end

function M.dedup_lines(lines)
  local seen, result = {}, {}
  for _, line in ipairs(lines) do
    if line ~= "" and not seen[line] then
      table.insert(result, line)
      seen[line] = true
    elseif line == "" then
      table.insert(result, line)
    end
  end
  return result
end

return M