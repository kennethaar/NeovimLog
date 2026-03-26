--- logseq.nvim parser
--- Parses a Logseq .md buffer into page properties + a block tree.
--- Pure Lua, no dependencies. Called on-demand by motions, editing, and link following.
---
---@class LogseqBlock
---@field line_start  integer
---@field line_end    integer
---@field indent      integer
---@field content     string
---@field properties  table<string,string>
---@field links       string[]
---@field tags        string[]
---@field children    LogseqBlock[]
---@field parent      LogseqBlock|nil
---
---@class ParseResult
---@field page_properties  table<string,string>
---@field blocks           LogseqBlock[]

local M = {}

-- ── Buffer-level parse cache (audit #18) ──────────────────────────────
-- Invalidated on TextChanged/TextChangedI. Most motions happen between
-- edits, so the cache has a high hit rate.

local _cache = {} -- bufnr → { changedtick, result }

--- Get the parse result for a buffer, using cache when possible.
---@param bufnr integer|nil  defaults to current buffer
---@return ParseResult
---@return string[]  lines
function M.parse_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _cache[bufnr]

  if cached and cached.tick == tick then
    return cached.result, cached.lines
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local result = M.parse(lines)
  _cache[bufnr] = { tick = tick, result = result, lines = lines }
  return result, lines
end

--- Invalidate cache for a buffer (called on BufUnload).
---@param bufnr integer
function M.invalidate_cache(bufnr)
  _cache[bufnr] = nil
end

-- ── Line classifiers ──────────────────────────────────────────────────

---@param line string
---@return integer|nil indent
---@return string|nil content
local function match_bullet(line)
  local spaces, content = line:match("^(%s*)%- (.+)$")
  if spaces then return #spaces, content end
  spaces = line:match("^(%s*)%- $")
  if spaces then return #spaces, "" end
  return nil, nil
end

---@param line string
---@return integer|nil indent
---@return string|nil key
---@return string|nil value
local function match_property(line)
  local spaces, key, value = line:match("^(%s*)([%w_%-]+):: (.*)$")
  if spaces then return #spaces, key, value end
  spaces, key = line:match("^(%s*)([%w_%-]+)::$")
  if spaces then return #spaces, key, "" end
  return nil, nil, nil
end

---@param line string
---@return integer
local function leading_spaces(line)
  local s = line:match("^(%s*)")
  return s and #s or 0
end

-- ── Extractors ────────────────────────────────────────────────────────

---@param text string
---@return string[]
local function extract_links(text)
  local links = {}
  for link in text:gmatch("%[%[(.-)%]%]") do
    -- Strip pipe alias: [[Page|Alias]] → "Page"
    links[#links + 1] = link:match("^(.-)%|") or link
  end
  return links
end

---@param text string
---@return string[]
local function extract_tags(text)
  local tags = {}
  local clean = text:gsub("%[%[.-%]%]", "")
  for tag in clean:gmatch("#([%w_%-/]+)") do
    tags[#tags + 1] = tag
  end
  return tags
end

---@param text string
---@return string[]  ISO dates "YYYY-MM-DD" from Org/Logseq angle-bracket timestamps
local function extract_org_dates(text)
  local dates = {}
  for y, m, d in text:gmatch("<(%d%d%d%d)-(%d%d)-(%d%d)[^>]*>") do
    dates[#dates + 1] = y .. "-" .. m .. "-" .. d
  end
  return dates
end

-- ── Main parser ───────────────────────────────────────────────────────

---@param lines string[]
---@return ParseResult
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
      local pi, key, value = match_property(line)
      if key and pi == 0 then page_props[key] = value end
      i = i + 1
    end
  end

  -- Pass 2: parse blocks into a flat ordered list
  local flat = {} ---@type LogseqBlock[]

  while i <= #lines do
    local indent, content = match_bullet(lines[i])

    if indent then
      local block = {
        line_start  = i,
        line_end    = i,
        indent      = indent,
        content     = content,
        properties  = {},
        links       = extract_links(content),
        tags        = extract_tags(content),
        children    = {},
        parent      = nil,
      }
      -- Org-mode timestamps inline on the bullet line: SCHEDULED:: <2026-04-01 Wed>
      for _, d in ipairs(extract_org_dates(content)) do
        block.links[#block.links + 1] = d
      end

      local j = i + 1
      while j <= #lines do
        local line = lines[j]

        if match_bullet(line) then break end
        if line:match("^%s*$") then break end

        local pi, pkey, pvalue = match_property(line)
        if pkey and pi == indent + 2 then
          block.properties[pkey] = pvalue
          for _, link in ipairs(extract_links(pvalue)) do
            block.links[#block.links + 1] = link
          end
          -- Org-mode timestamps in property values: SCHEDULED:: <2026-04-01 Wed>
          for _, d in ipairs(extract_org_dates(pvalue)) do
            block.links[#block.links + 1] = d
          end
          block.line_end = j
          j = j + 1
        elseif leading_spaces(line) >= indent + 2 then
          -- Timestamp may appear on its own continuation line after SCHEDULED::
          for _, d in ipairs(extract_org_dates(line)) do
            block.links[#block.links + 1] = d
          end
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

  -- Pass 3: build tree using indent-based stack
  local roots = {} ---@type LogseqBlock[]
  local stack = {} ---@type LogseqBlock[]

  for _, block in ipairs(flat) do
    while #stack > 0 and stack[#stack].indent >= block.indent do
      table.remove(stack)
    end

    if #stack > 0 then
      local parent = stack[#stack]
      block.parent = parent
      parent.children[#parent.children + 1] = block
    else
      roots[#roots + 1] = block
    end

    stack[#stack + 1] = block
  end

  -- Pass 4: propagate line_end upward
  local function propagate_line_end(block)
    for _, child in ipairs(block.children) do
      propagate_line_end(child)
      if child.line_end > block.line_end then
        block.line_end = child.line_end
      end
    end
  end
  for _, root in ipairs(roots) do
    propagate_line_end(root)
  end

  return { page_properties = page_props, blocks = roots }
end

-- ── Tree helpers ──────────────────────────────────────────────────────

--- Depth-first flatten of a block tree.
---@param blocks LogseqBlock[]
---@return LogseqBlock[]
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

--- Find the deepest block whose range contains lnum.
--- Uses recursive descent instead of flatten+scan (audit #19).
---@param blocks LogseqBlock[]
---@param lnum integer
---@return LogseqBlock|nil
function M.block_at_line(blocks, lnum)
  for _, b in ipairs(blocks) do
    if lnum < b.line_start then return nil end
    if lnum <= b.line_end then
      -- Check children first for a tighter match
      local child_match = M.block_at_line(b.children, lnum)
      if child_match then return child_match end
      -- lnum is within this block's own range (bullet + properties + continuations)
      return b
    end
  end
  return nil
end

--- Extract all [[links]] and #tags from page-level property values.
--- Returns a set (table keyed by string → true).
--- Applies ISO-date underscore→dash normalization to match norm_link in indexer.
---@param page_properties table<string,string>
---@return table<string,boolean>
function M.page_property_refs(page_properties)
  local refs = {}
  local function add(s)
    refs[s:gsub("^(%d%d%d%d)_(%d%d)_(%d%d)$", "%1-%2-%3")] = true
  end
  for _, value in pairs(page_properties) do
    for link in value:gmatch("%[%[(.-)%]%]") do
      add(link:match("^(.-)%|") or link)
    end
    local clean = value:gsub("%[%[.-%]%]", "")
    for tag in clean:gmatch("#([%w_%-/]+)") do
      add(tag)
    end
  end
  return refs
end

--- Get the sibling list a block belongs to.
---@param block LogseqBlock
---@param roots LogseqBlock[]
---@return LogseqBlock[]
function M.siblings(block, roots)
  if block.parent then return block.parent.children end
  return roots
end

--- Find a block's index within its sibling list.
---@param block LogseqBlock
---@param sibling_list LogseqBlock[]
---@return integer|nil
function M.sibling_index(block, sibling_list)
  for idx, sib in ipairs(sibling_list) do
    if sib.line_start == block.line_start then return idx end
  end
  return nil
end

return M
