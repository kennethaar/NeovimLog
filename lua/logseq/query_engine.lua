local config  = require("logseq.config")
local indexer = require("logseq.indexer")
local parser  = require("logseq.parser")
local util    = require("logseq.util")

local M = {}

local function get_todo_state(content)
  for _, state in ipairs(util.todo_states) do
    local prefix = state .. " "
    local upper  = content:upper()
    if upper:sub(1, #prefix) == prefix or upper == state then return state end
  end
end

local function effective_todo(block)
  local cur = block
  while cur do
    local s = get_todo_state(cur.content)
    if s then return s end
    cur = cur.parent
  end
end

local function effective_tags(block)
  local tags, seen = {}, {}
  local cur = block
  while cur do
    for _, tag in ipairs(cur.tags) do
      if not seen[tag] then seen[tag] = true; tags[#tags + 1] = tag end
    end
    cur = cur.parent
  end
  return tags
end

local function block_links_page(block, page_lower)
  local ns_prefix = page_lower .. "/"
  local cur = block
  while cur do
    for _, link in ipairs(cur.links) do
      local ll = link:lower()
      if ll == page_lower or ll:sub(1, #ns_prefix) == ns_prefix then return true end
    end
    cur = cur.parent
  end
  return false
end

local eval
local evaluators = {
  page_link = function(ast, block, ctx) local page = ast.page:lower() == "current page" and (ctx.current_page or ""):lower() or ast.page:lower(); return page ~= "" and block_links_page(block, page) end,
  todo = function(ast, _b, ctx) if not ctx.todo_state then return false end; for _, s in ipairs(ast.states) do if s == ctx.todo_state then return true end end; return false end,
  tags = function(ast, _b, ctx) local tag_set = {}; for _, t in ipairs(ctx.tags) do tag_set[t:lower()] = true end; for _, r in ipairs(ast.tags) do if not tag_set[r:lower()] then return false end end; return #ast.tags > 0 end,
  property = function(ast, block, _c) local key = ast.key:lower():gsub("^:", ""); local val = util.prop_ci(block.properties, key); if not val then return false end; if not ast.value then return true end; return val:lower() == ast.value:lower() end,
  page_property = function(ast, _b, ctx) local key = ast.key:lower():gsub("^:", ""); local val = util.prop_ci(ctx.page_props, key); if not val then return false end; if not ast.value then return true end; return val:lower() == ast.value:lower() end,
  between = function(ast, _b, ctx) if not ctx.journal_date then return false end; return ctx.journal_date >= ast.from and ctx.journal_date <= ast.to end,
  ["and"] = function(ast, block, ctx) for _, child in ipairs(ast.children) do if not eval(child, block, ctx) then return false end end; return true end,
  ["or"] = function(ast, block, ctx) for _, child in ipairs(ast.children) do if eval(child, block, ctx) then return true end end; return false end,
  ["not"] = function(ast, block, ctx) return not eval(ast.children[1], block, ctx) end,
}
evaluators["task"] = evaluators["todo"]

eval = function(ast, block, ctx) if not ast then return false end; local fn = evaluators[ast.type]; return fn and fn(ast, block, ctx) or false end

local function journal_date(filepath)
  local stem = filepath:match("[/\\]journals[/\\](.+)%.md$")
  if not stem then return nil end
  local y, m, d = stem:match("^(%d%d%d%d)[_%-](%d%d)[_%-](%d%d)")
  return y and (y .. "-" .. m .. "-" .. d) or nil
end

-- NEW ASYNC process_file
local function process_file_async(filepath, ast, opts, results, on_done)
  indexer.get_parsed_file_async(filepath, function(_lines, parsed)
    -- Guard clause if file read fails or fails to parse
    if not parsed then 
      return on_done() 
    end

    local source_page = indexer.page_name_from_file and indexer.page_name_from_file(filepath) or vim.fn.fnamemodify(filepath, ":t:r")
    local jdate = journal_date(filepath)
    
    for _, block in ipairs(parser.flatten(parsed.blocks)) do
      local ctx = { 
        todo_state = effective_todo(block), 
        tags = effective_tags(block), 
        journal_date = jdate, 
        page_props = parsed.page_properties, 
        current_page = opts.current_page 
      }
      
      if eval(ast, block, ctx) then 
        table.insert(results, { 
          source_page = source_page, 
          source_file = filepath, 
          content = block.content, 
          line_start = block.line_start, 
          todo_state = ctx.todo_state, 
          tags = ctx.tags, 
          date = jdate, 
          properties = block.properties 
        }) 
      end
    end
    
    -- Always call on_done() to signal the batch processor to continue
    on_done()
  end)
end

function M.run(ast, opts, on_complete)
  local vault = config.current.vault_path
  if not vault or vault == "" then return vim.schedule(function() on_complete({}) end) end

  local all_files = util.get_vault_files(vault)
  if #all_files == 0 then return vim.schedule(function() on_complete({}) end) end

  local results = {}

  -- Use the robust async batcher exported from indexer.lua
  indexer.process_file_list_batched(
    all_files,
    -- The file processor callback
    function(filepath, _, on_file_done)
      process_file_async(filepath, ast, opts, results, on_file_done)
    end,
    -- The on_complete callback when all files are done
    function()
      table.sort(results, function(x, y)
        if x.source_page ~= y.source_page then return x.source_page < y.source_page end
        return x.line_start < y.line_start
      end)
      on_complete(results)
    end
  )
end

return M