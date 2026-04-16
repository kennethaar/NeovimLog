local M = {}
function M.read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  return content
end
function M.safe_write(path, content)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end
function M.backup_file(path, vault, content)
  local name = vim.fn.fnamemodify(path, ":t")
  local bdir = vault .. "/bak"
  if vim.fn.isdirectory(bdir) == 0 then vim.fn.mkdir(bdir, "p") end
  local bpath = bdir .. "/" .. name .. "." .. os.date("%Y%m%d%H%M%S") .. ".bak"
  M.safe_write(bpath, content)
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
