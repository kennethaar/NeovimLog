local M = {}
local _cache = {}

function M.parse_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if _cache[bufnr] and _cache[bufnr].tick == tick then return _cache[bufnr].result, _cache[bufnr].lines end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local result = M.parse(lines)
  _cache[bufnr] = { tick = tick, result = result, lines = lines }
  return result, lines
end

function M.parse(lines)
  local page_props, i = {}, 1
  while i <= #lines do
    local line = lines[i]
    local k, v = line:match("^([%w_%-]+)::%s*(.*)$")
    if k and not line:match("^%s*-") then page_props[k] = v elseif line:match("^%s*-") then break end
    i = i + 1
  end

  local flat = {}
  while i <= #lines do
    local indent, content = lines[i]:match("^(%s*)%- (.*)$")
    if indent then
      local block = { line_start = i, line_end = i, indent = #indent, content = content, properties = {}, children = {}, parent = nil, links = vim.iter(content:gmatch("%[%[(.-)%]%.]")):map(function(l) return l:match("^(.-)%|") or l end):totable(), tags = {} }
      local j = i + 1
      while j <= #lines and not lines[j]:match("^%s*-") and lines[j] ~= "" do
        local pk, pv = lines[j]:match("^(%s*)([%w_%-]+)::%s*(.*)$")
        if pk and #pk <= block.indent + 2 then block.properties[pk] = pv end
        block.line_end, j = j, j + 1
      end
      table.insert(flat, block)
      i = j
    else i = i + 1 end
  end

  local roots, stack = {}, {}
  for _, block in ipairs(flat) do
    while #stack > 0 and stack[#stack].indent >= block.indent do table.remove(stack) end
    if #stack > 0 then block.parent = stack[#stack]; table.insert(block.parent.children, block) else table.insert(roots, block) end
    table.insert(stack, block)
  end
  return { page_properties = page_props, blocks = roots }
end

function M.flatten(blocks)
  return vim.iter(blocks):map(function(b) return vim.iter({b, M.flatten(b.children)}):flatten() end):flatten():totable()
end

function M.block_at_line(blocks, lnum)
  for _, b in ipairs(blocks) do
    if lnum >= b.line_start and lnum <= b.line_end then
      local child_match = M.block_at_line(b.children, lnum)
      return child_match or b
    end
  end
  return nil
end

function M.page_property_refs(page_properties) return {} end -- Keep interface for backcompat if needed, logic shifted
function M.siblings(block, roots) return block.parent and block.parent.children or roots end
function M.sibling_index(block, sibling_list) for idx, sib in ipairs(sibling_list) do if sib.line_start == block.line_start then return idx end end return nil end

return M
