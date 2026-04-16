local M = {}

local function line_indent(line)
  local spaces = line:match("^(%s*)")
  if not spaces then return 0 end
  local _, tabs = spaces:gsub("\t", "")
  return #spaces + (tabs * 3) -- Normalize tabs to 4-space width
end

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
        local next_line = lines[i]
        if next_line == "" or line_indent(next_line) <= indent then break end
        block.body[#block.body + 1] = next_line
        i = i + 1
      end
      blocks[#blocks + 1] = block
    end
  end
  return blocks
end

local function flatten_blocks(blocks)
  local lines = {}
  for _, b in ipairs(blocks) do
    lines[#lines + 1] = b.line
    vim.list_extend(lines, b.body)
  end
  return lines
end

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

function M.dedup_lines(lines)
  if #lines == 0 then return {}, 0 end
  local result = flatten_blocks(dedup_block_list(lines, 0))
  return result, #lines - #result
end

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- Atomic Write with Metadata Preservation
function M.safe_write(path, content)
  local stat = vim.uv.fs_stat(path)
  local mode = stat and stat.mode or 438
  local tmp = path .. ".tmp_" .. math.random(1000, 9999)
  
  local fd = vim.uv.fs_open(tmp, "w", mode)
  if not fd then return false end
  
  vim.uv.fs_write(fd, content)
  vim.uv.fs_close(fd)
  
  local ok, err = vim.uv.fs_rename(tmp, path)
  if not ok then 
    os.remove(tmp)
    return false, err 
  end
  return true
end

function M.backup_file(filepath, vault, content)
  local backup_dir = vault .. "/deduped"
  vim.fn.mkdir(backup_dir, "p")
  local stem = vim.fn.fnamemodify(filepath, ":t:r")
  local ext  = vim.fn.fnamemodify(filepath, ":e")
  local ts   = os.date("%Y-%m-%d_%H%M%S")
  local dest = backup_dir .. "/" .. stem .. "_" .. ts .. "." .. ext
  M.safe_write(dest, content)
end

-- [ ... Include dedup_buf and dedup_vault as provided in your snippet, 
--   but ensure they call M.safe_write and M.backup_file ... ]

return M