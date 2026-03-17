--- logseq.nvim parser
--- Parses a Logseq .md buffer into page properties + a block tree.
--- Pure Lua, no dependencies. Called on-demand by motions and link following.
---
--- Minimal block struct (Phase 1-2-4):
---@class LogseqBlock
---@field line_start  integer          1-indexed, the `- ` bullet line
---@field line_end    integer          last line of this block (inclusive of props/continuations/children)
---@field indent      integer          column of the `- ` marker (0, 2, 4, ...)
---@field content     string           text after `- ` on the bullet line
---@field properties  table<string,string>  key::value pairs directly on this block
---@field links       string[]         [[refs]] found on the bullet line + property values
---@field tags        string[]         #tags found on the bullet line
---@field children    LogseqBlock[]
---@field parent      LogseqBlock|nil
---
---@class ParseResult
---@field page_properties  table<string,string>
---@field blocks           LogseqBlock[]   root-level blocks (children nested inside)

local M = {}

-- ── Line classifiers ──────────────────────────────────────────────────

--- Try to parse a line as a bullet. Returns indent and content, or nil.
---@param line string
---@return integer|nil indent
---@return string|nil content
local function match_bullet(line)
  local spaces, content = line:match("^(%s*)%- (.+)$")
  if spaces then return #spaces, content end
  -- Empty bullet: `- ` with nothing after
  spaces = line:match("^(%s*)%- $")
  if spaces then return #spaces, "" end
  return nil, nil
end

--- Try to parse a line as a property. Returns indent, key, value, or nil.
---@param line string
---@return integer|nil indent
---@return string|nil key
---@return string|nil value
local function match_property(line)
  local spaces, key, value = line:match("^(%s*)([%w_%-]+):: (.*)$")
  if spaces then return #spaces, key, value end
  -- Empty-value property: `key::` with nothing after
  spaces, key = line:match("^(%s*)([%w_%-]+)::$")
  if spaces then return #spaces, key, "" end
  return nil, nil, nil
end

--- Count leading whitespace on a line.
---@param line string
---@return integer
local function leading_spaces(line)
  local s = line:match("^(%s*)")
  return s and #s or 0
end

-- ── Extractors (bullet line only) ─────────────────────────────────────

--- Extract all [[links]] from a string.
---@param text string
---@return string[]
local function extract_links(text)
  local links = {}
  for link in text:gmatch("%[%[(.-)%]%]") do
    links[#links + 1] = link
  end
  return links
end

--- Extract all #tags from a string, ignoring tags inside [[...]].
---@param text string
---@return string[]
local function extract_tags(text)
  local tags = {}
  -- Strip [[...]] so we don't match # inside wikilinks
  local clean = text:gsub("%[%[.-%]%]", "")
  for tag in clean:gmatch("#([%w_%-/]+)") do
    tags[#tags + 1] = tag
  end
  return tags
end

-- ── Main parser ───────────────────────────────────────────────────────

--- Parse buffer lines into page properties and a block tree.
---@param lines string[]  0-indexed content from nvim_buf_get_lines, but we treat as 1-indexed here
---@return ParseResult
function M.parse(lines)
  local page_props = {}
  local i = 1

  -- Pass 1: page properties (top of file, before first bullet)
  while i <= #lines do
    local line = lines[i]
    if line:match("^%s*$") then
      i = i + 1 -- skip blank lines
    elseif match_bullet(line) then
      break -- first block found, stop
    else
      local pi, key, value = match_property(line)
      if key and pi == 0 then
        page_props[key] = value
        i = i + 1
      else
        i = i + 1 -- unknown non-bullet line before blocks, skip
      end
    end
  end

  -- Pass 2: parse blocks into a flat ordered list
  local flat = {} ---@type LogseqBlock[]

  while i <= #lines do
    local indent, content = match_bullet(lines[i])

    if indent then
      local block = {
        line_start  = i,
        line_end    = i, -- will extend below
        indent      = indent,
        content     = content,
        properties  = {},
        links       = extract_links(content),
        tags        = extract_tags(content),
        children    = {},
        parent      = nil,
      }

      -- Consume property and continuation lines following the bullet
      local j = i + 1
      while j <= #lines do
        local line = lines[j]

        -- Is it another bullet? → stop, it's a new block
        if match_bullet(line) then
          break
        end

        -- Is it a blank line? → stop (Logseq treats blanks as block separators)
        if line:match("^%s*$") then
          break
        end

        -- Is it a property at indent+2? (block properties sit 2 spaces deeper than bullet)
        local pi, pkey, pvalue = match_property(line)
        if pkey and pi == indent + 2 then
          block.properties[pkey] = pvalue
          -- Extract links from property values (needed for gf on id::, and later for path-refs)
          for _, link in ipairs(extract_links(pvalue)) do
            block.links[#block.links + 1] = link
          end
          block.line_end = j
          j = j + 1
        elseif leading_spaces(line) >= indent + 2 then
          -- Continuation line (same or deeper indent, not a bullet, not a property)
          block.line_end = j
          j = j + 1
        else
          break
        end
      end

      flat[#flat + 1] = block
      i = j
    else
      i = i + 1 -- blank or unrecognized line between blocks
    end
  end

  -- Pass 3: build tree from flat list using indent-based stack
  local roots = {} ---@type LogseqBlock[]
  local stack = {} ---@type LogseqBlock[]  -- ancestry from root down to current parent

  for _, block in ipairs(flat) do
    -- Pop stack until top has indent strictly less than this block
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

  -- Pass 4: propagate line_end upward so each block's range covers all descendants
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

-- ── Tree helpers (used by motions and links) ──────────────────────────

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
--- Prefers the block whose line_start is closest to lnum from above.
---@param blocks LogseqBlock[]
---@param lnum integer
---@return LogseqBlock|nil
function M.block_at_line(blocks, lnum)
  local flat = M.flatten(blocks)
  local best = nil
  for _, b in ipairs(flat) do
    if lnum >= b.line_start and lnum <= b.line_end then
      if not best or b.line_start >= best.line_start then
        best = b
      end
    end
  end
  return best
end

--- Get the sibling list a block belongs to.
---@param block LogseqBlock
---@param roots LogseqBlock[]
---@return LogseqBlock[]
function M.siblings(block, roots)
  if block.parent then
    return block.parent.children
  end
  return roots
end

--- Find a block's index within its sibling list.
---@param block LogseqBlock
---@param sibling_list LogseqBlock[]
---@return integer|nil
function M.sibling_index(block, sibling_list)
  for idx, sib in ipairs(sibling_list) do
    if sib.line_start == block.line_start then
      return idx
    end
  end
  return nil
end

return M
