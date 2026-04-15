local M = {}
local _cache = {}

function M.invalidate_cache(bufnr) _cache[bufnr] = nil end

function M.parse_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _cache[bufnr]
  if cached and cached.tick == tick then return cached.result, cached.lines end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local result = M.parse(lines)
  _cache[bufnr] = { tick = tick, result = result, lines = lines }
  return result, lines
end

-- ── Line classifiers ───────────────────────────────────────────────────

local function match_bullet(line)
  local sp, content = line:match("^(%s*)%- (.+)$")
  if sp then return #sp, content end
  sp = line:match("^(%s*)%- $")
  if sp then return #sp, "" end
  sp = line:match("^(%s*)%-$")
  if sp then return #sp, "" end
  return nil
end

local function match_property(line)
  local sp, k, v = line:match("^(%s*)([%w_%-]+):: (.*)$")
  if sp then return #sp, k, v end
  sp, k = line:match("^(%s*)([%w_%-]+)::$")
  if sp then return #sp, k, "" end
  return nil
end

local function leading_spaces(line)
  local s = line:match("^(%s*)")
  return s and #s or 0
end

-- ── Extractors (vim.iter pipelines where natural) ──────────────────────

local function extract_links(text)
  return vim.iter(text:gmatch("%[%[(.-)%]%]"))
    :map(function(l) return l:match("^(.-)%|") or l end)
    :totable()
end

local function extract_tags(text)
  -- Strip wiki-links first so `[[foo #bar]]` doesn't yield `bar`
  local clean = text:gsub("%[%[.-%]%]", "")
  return vim.iter(clean:gmatch("#([%w_%-/]+)")):totable()
end

local function extract_org_dates(text)
  -- gmatch returns multi-captures; build explicitly (vim.iter + multi-capture
  -- gmatch is fragile across nvim versions).
  local dates = {}
  for y, m, d in text:gmatch("<(%d%d%d%d)-(%d%d)-(%d%d)[^>]*>") do
    dates[#dates + 1] = y .. "-" .. m .. "-" .. d
  end
  return dates
end

local function has_schedule_keyword(line)
  local ll = line:lower()
  return ll:find("scheduled:", 1, true) ~= nil or ll:find("deadline:", 1, true) ~= nil
end

-- ── Main parser ────────────────────────────────────────────────────────

function M.parse(lines)
  local page_props = {}
  local i = 1

  -- Pass 1: page properties (top of file, before first bullet)
  while i <= #lines do
    local line = lines[i]
    if line:match("^%s*$") then
      i = i + 1
    elseif match_bullet(line) then
      break
    else
      local pi, k, v = match_property(line)
      if k and pi == 0 then page_props[k] = v end
      i = i + 1
    end
  end

  -- Pass 2: flat block list with properties + continuation lines
  local flat = {}
  while i <= #lines do
    local indent, content = match_bullet(lines[i])
    if indent then
      local links = extract_links(content)
      for _, d in ipairs(extract_org_dates(content)) do links[#links + 1] = d end
      local block = {
        line_start   = i,
        line_end     = i,
        indent       = indent,
        content      = content,
        properties   = {},
        links        = links,
        tags         = extract_tags(content),
        is_scheduled = has_schedule_keyword(content),
        children     = {},
        parent       = nil,
      }

      local j = i + 1
      while j <= #lines do
        local line = lines[j]
        if match_bullet(line) then break end
        if line:match("^%s*$") then break end

        local pi, pk, pv = match_property(line)
        if pk and (pi == indent + 2 or pi == indent) then
          block.properties[pk] = pv
          local pl = pk:lower()
          if pl == "scheduled" or pl == "deadline" then block.is_scheduled = true end
          for _, l in ipairs(extract_links(pv)) do block.links[#block.links + 1] = l end
          for _, d in ipairs(extract_org_dates(pv)) do block.links[#block.links + 1] = d end
          block.line_end = j
          j = j + 1
        elseif leading_spaces(line) >= indent then
          -- Continuation line (wrapped text, bare timestamp, single-colon SCHEDULED, …)
          for _, d in ipairs(extract_org_dates(line)) do block.links[#block.links + 1] = d end
          if has_schedule_keyword(line) then block.is_scheduled = true end
          block.line_end = j
          j = j + 1
        else
          break
        end
      end

      flat[#flat + 1] = block
      i = j
    else
      i = i + 1
    end
  end

  -- Pass 3: build tree with an indent-stack
  local roots, stack = {}, {}
  for _, block in ipairs(flat) do
    while #stack > 0 and stack[#stack].indent >= block.indent do table.remove(stack) end
    if #stack > 0 then
      block.parent = stack[#stack]
      local siblings = stack[#stack].children
      siblings[#siblings + 1] = block
    else
      roots[#roots + 1] = block
    end
    stack[#stack + 1] = block
  end

  -- Pass 4: propagate line_end upward so a block's range spans its subtree
  local function propagate(b)
    for _, c in ipairs(b.children) do
      propagate(c)
      if c.line_end > b.line_end then b.line_end = c.line_end end
    end
  end
  for _, r in ipairs(roots) do propagate(r) end

  return { page_properties = page_props, blocks = roots }
end

-- ── Tree helpers ───────────────────────────────────────────────────────

function M.flatten(blocks)
  local result = {}
  local function walk(list)
    for _, b in ipairs(list) do
      result[#result + 1] = b
      walk(b.children)
    end
  end
  walk(blocks)
  return result
end

function M.block_at_line(blocks, lnum)
  for _, b in ipairs(blocks) do
    if lnum < b.line_start then return nil end
    if lnum <= b.line_end then
      local child = M.block_at_line(b.children, lnum)
      return child or b
    end
  end
  return nil
end

-- Extract all [[links]], #tags, and <YYYY-MM-DD> dates from page-property values.
-- Returns a set keyed by lowercased ref. Journal-style YYYY_MM_DD is normalized
-- to YYYY-MM-DD to align with the indexer's norm_link conventions.
function M.page_property_refs(page_properties)
  local refs = {}
  local function add(s)
    refs[s:gsub("^(%d%d%d%d)_(%d%d)_(%d%d)$", "%1-%2-%3"):lower()] = true
  end
  for _, v in pairs(page_properties) do
    for _, l in ipairs(extract_links(v)) do add(l) end
    for _, t in ipairs(extract_tags(v)) do add(t) end
    for _, d in ipairs(extract_org_dates(v)) do add(d) end
  end
  return refs
end

function M.siblings(block, roots) return block.parent and block.parent.children or roots end

function M.sibling_index(block, sibling_list)
  for idx, sib in ipairs(sibling_list) do
    if sib.line_start == block.line_start then return idx end
  end
  return nil
end

return M
