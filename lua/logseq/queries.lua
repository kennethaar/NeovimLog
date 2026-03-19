local config = require("logseq.config")
local M = {}

local START_DELIM = ""
local END_DELIM = ""

local todo_states = { "TODO", "DOING", "WAITING" }

-- Helper: Check if a line is an active task
local function is_active_task(line)
  for _, state in ipairs(todo_states) do
    if line:match("^%s*%- " .. state .. "%s+") then
      return true
    end
  end
  return false
end

-- Helper: Process a single file (Pure Lua, cross-platform)
local function process_single_file(filepath, page_link, all_todos, very_next_todos)
  local f = io.open(filepath, "r")
  if not f then return end -- Guard clause: unreadable file

  -- FAST PRE-CHECK: Read entire file to see if it even contains the link
  local content = f:read("*all")
  if not content or not content:find(page_link, 1, true) then
    f:close()
    return -- Guard clause: Link not found, skip line-by-line parsing
  end

  -- Reset file pointer to beginning for line-by-line hierarchical parsing
  f:seek("set", 0)

  local source_page = vim.fn.fnamemodify(filepath, ":t"):gsub("%.md$", ""):gsub("___", "/")
  local indent_stack = {}

  for line in f:lines() do
    local indent_str = line:match("^(%s*)%-")
    
    -- If it's a bullet point, process it
    if indent_str then
      local indent = #indent_str
      
      -- Manage hierarchy stack based on indentation
      while #indent_stack > 0 and indent_stack[#indent_stack].indent >= indent do
        table.remove(indent_stack)
      end
      
      local current_is_task = is_active_task(line)
      local parent_is_task = false
      
      -- Check if any parent in the current tree is an active task
      for _, parent in ipairs(indent_stack) do
        if parent.is_task then 
          parent_is_task = true 
          break 
        end
      end
      
      table.insert(indent_stack, { indent = indent, is_task = current_is_task })
      
      -- Is it an active task that references our page?
      if current_is_task and line:find(page_link, 1, true) then
        local clean_task = vim.trim(line:gsub("^%s*%- ", ""))
        
        table.insert(all_todos, { task = clean_task, source = source_page })
        
        -- If no parent is an active task, it is a "very next" action
        if not parent_is_task then
          table.insert(very_next_todos, { task = clean_task, source = source_page })
        end
      end
    end
  end

  f:close()
end

-- Pure Lua scanner matching the page_search/backlinks pattern
local function gather_tasks(page_name)
  local vault = config.current.vault_path
  if not vault or vault == "" then return {}, {} end

  local page_link = "[[" .. page_name .. "]]"
  local files = {}

  -- Fetch files natively without grep
  local function scan_dir(dir)
    if vim.fn.isdirectory(dir) == 0 then return end
    local md_files = vim.fn.glob(dir .. "/*.md", true, true)
    for _, file in ipairs(md_files) do
      table.insert(files, file)
    end
  end

  scan_dir(vault .. "/pages")
  scan_dir(vault .. "/journals")
  
  local all_todos = {}
  local very_next_todos = {}

  for _, filepath in ipairs(files) do
    process_single_file(filepath, page_link, all_todos, very_next_todos)
  end
  
  return all_todos, very_next_todos
end

-- Helper: Generate markdown table
local function build_table(tasks, heading_title)
  local lines = {
    string.format("### %d %s", #tasks, heading_title),
    "",
    "| Task | Source |",
    "|---|---|",
  }
  
  if #tasks == 0 then
    table.insert(lines, "| *No tasks found* | |")
  else
    for _, t in ipairs(tasks) do
      table.insert(lines, string.format("| %s | [[%s]] |", t.task, t.source))
    end
  end
  
  table.insert(lines, "")
  return lines
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  
  local start_idx, end_idx = nil, nil
  for i, line in ipairs(lines) do
    if line == START_DELIM then start_idx = i - 1 end
    if line == END_DELIM then end_idx = i end
  end

  -- TOGGLE OFF: If delimiters exist, remove the region
  if start_idx and end_idx then
    vim.api.nvim_buf_set_lines(bufnr, start_idx, end_idx, false, {})
    vim.cmd("silent! w")
    return
  end

  -- TOGGLE ON: Setup requirements
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local filename = vim.fn.fnamemodify(filepath, ":t")
  local namespace = filename:match("^(.-)___")
  
  if not namespace then
    vim.notify("Not in a namespace. Cannot apply queries.", vim.log.levels.WARN)
    return
  end

  local query_path = config.current.vault_path .. "/pages/Query___" .. namespace .. ".md"
  local f = io.open(query_path, "r")
  if not f then
    vim.notify("No Query___" .. namespace .. ".md found.", vim.log.levels.WARN)
    return
  end
  
  local query_content = f:read("*all")
  f:close()

  -- Execute queries
  local page_name = filename:gsub("%.md$", ""):gsub("___", "/")
  local all_todos, very_next_todos = gather_tasks(page_name)

  -- Build injection payload
  local new_lines = { "", START_DELIM, "---", "## Queries" }
  
  for line in query_content:gmatch("([^\n]*)\n?") do
    if line == "%QueryTodos%" then
      vim.list_extend(new_lines, build_table(all_todos, "Actions"))
    elseif line == "%QueryVeryNextTodos%" then
      vim.list_extend(new_lines, build_table(very_next_todos, "Very next actions"))
    elseif line ~= "" then
      table.insert(new_lines, line)
    end
  end
  
  table.insert(new_lines, END_DELIM)

  -- Inject at EOF
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_lines)
  vim.cmd("silent! w")
end

-- Let other modules check if cursor is in read-only zone
function M.in_region(bufnr, row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local start_idx = nil
  for i, line in ipairs(lines) do
    if line == START_DELIM then start_idx = i end
    if line == END_DELIM and start_idx then
      return row >= start_idx and row <= i
    end
  end
  return false
end

function M.setup_buf(bufnr)
  vim.keymap.set("n", "<Leader>q", M.toggle, { buffer = bufnr, desc = "Logseq: Toggle Queries" })
end

return M