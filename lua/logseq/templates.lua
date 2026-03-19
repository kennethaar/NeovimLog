local config = require("logseq.config")
local M = {}

-- Helper to find and read the template file from the vault
local function get_template_content(namespace)
  local vault = config.current.vault_path
  if not vault then return nil end

  local template_path = vault .. "/pages/Templates___" .. namespace .. ".md"
  local f = io.open(template_path, "r")
  if not f then return nil end

  local content = f:read("*all")
  f:close()
  return content
end

-- Helper to determine the best prompt text for a placeholder.
-- If the current line has text (like "status:: "), it uses it.
-- If the current line is just a bullet ("- %TEXT%"), it scans up to find the parent.
local function get_prompt_text(lines, current_idx)
  local line = lines[current_idx]
  local prefix = line:match("^(.-)%%") or ""
  
  -- Remove leading spaces and bullets to see if there's actual text
  local clean_prefix = vim.trim(prefix:gsub("^%s*%-?%s*", ""))
  
  if #clean_prefix > 0 then
    return clean_prefix
  end
  
  -- If we are here, the line is likely just "  - %TEXT%". Look for the parent.
  local current_indent = #(line:match("^(%s*)") or "")
  
  for i = current_idx - 1, 1, -1 do
    local prev_line = lines[i]
    local prev_indent = #(prev_line:match("^(%s*)") or "")
    
    -- Find the first line above that has LESS indentation and isn't empty
    if prev_indent < current_indent and vim.trim(prev_line) ~= "" then
      -- Clean up the parent text (remove its bullet)
      local parent_text = vim.trim(prev_line:gsub("^%s*%-?%s*", ""))
      return parent_text
    end
  end
  
  return "Value"
end

-- Processes placeholders using an asynchronous while loop to prevent stack overflows
local function process_placeholders(content, callback)
  local lines = {}
  for line in content:gmatch("([^\n]*)\n?") do table.insert(lines, line) end
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end

  local final_lines = {}
  
  local function process_from(idx)
    while idx <= #lines do
      local line = lines[idx]

      -- 1. Alternatives: %Opt 1% / %Opt 2%
      if line:match("%%.-%% / %%.-%%") then
        local alts = {}
        for alt in line:gmatch("%%(.-)%%") do table.insert(alts, alt) end
        
        local prompt_text = get_prompt_text(lines, idx)
        
        vim.ui.select(alts, { 
          prompt = "Select for " .. prompt_text,
        }, function(choice)
          local replacement = choice or ""
          local new_line = line:gsub("%%.-%% / .*%%.-%%", replacement)
          table.insert(final_lines, new_line)
          process_from(idx + 1) -- Resume loop asynchronously
        end)
        return -- HALT synchronous execution to wait for UI

      -- 2. Free Text: %TEXT%
      elseif line:match("%%TEXT%%") then
        local prompt_text = get_prompt_text(lines, idx)
        
        vim.ui.input({ 
          prompt = "Fill " .. prompt_text .. ": ",
        }, function(input)
          local replacement = input or ""
          local new_line = line:gsub("%%TEXT%%", replacement)
          table.insert(final_lines, new_line)
          process_from(idx + 1) -- Resume loop asynchronously
        end)
        return -- HALT synchronous execution to wait for UI

      -- 3. Standard text (No placeholders)
      else
        table.insert(final_lines, line)
        idx = idx + 1
      end
    end
    
    -- Loop finished
    callback(final_lines)
  end

  process_from(1)
end

function M.apply_template(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local filename = vim.fn.fnamemodify(filepath, ":t")
  
  local namespace = filename:match("^(.-)___")

  if namespace and namespace ~= "Templates" then
    local raw_content = get_template_content(namespace)
    if raw_content then
      process_placeholders(raw_content, function(processed_lines)
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, processed_lines)
            vim.cmd("silent! w")
          end
        end)
      end)
    end
  end
end

function M.setup_buf(bufnr)
  vim.keymap.set("n", "<Leader>t", function() M.apply_template(bufnr) end, { buffer = bufnr, desc = "Logseq: Apply Template" })
end

return M