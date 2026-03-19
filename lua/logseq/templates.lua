local config = require("logseq.config")
local M = {}

-- Helper to find and read the template file from the vault
local function get_template_content(namespace)
  local vault = config.current.vault_path
  if not vault then return nil end

  -- Logseq namespaces use ___ as a separator in filenames
  local template_path = vault .. "/pages/Templates___" .. namespace .. ".md"
  local f = io.open(template_path, "r")
  if not f then return nil end

  local content = f:read("*all")
  f:close()
  return content
end

-- Processes placeholders sequentially so UI prompts don't overlap
local function process_placeholders(content, callback)
  local lines = {}
  for line in content:gmatch("([^\n]*)\n?") do table.insert(lines, line) end
  -- Clean up trailing empty line from gmatch
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end

  local final_lines = {}
  
  local function process_line(idx)
    if idx > #lines then
      callback(final_lines)
      return
    end

    local line = lines[idx]

    -- 1. Check for Alternatives: %Opt 1% / %Opt 2%
    if line:match("%%.-%% / %%.-%%") then
      local alts = {}
      for alt in line:gmatch("%%(.-)%%") do table.insert(alts, alt) end
      
      -- Extract the text before the placeholders to use as a prompt
      local prompt_text = line:match("^(.-)%%") or "Choose:"
      
      vim.ui.select(alts, { 
        prompt = "Select for " .. vim.trim(prompt_text),
      }, function(choice)
        -- If user hits ESC (choice is nil), we leave the line blank/empty per request
        local replacement = choice or ""
        local new_line = line:gsub("%%.-%% / .*%%.-%%", replacement)
        table.insert(final_lines, new_line)
        process_line(idx + 1)
      end)

    -- 2. Check for Free Text: %TEXT%
    elseif line:match("%%TEXT%%") then
      local prompt_text = line:match("^(.-)%%") or "Enter text:"
      
      vim.ui.input({ 
        prompt = "Fill " .. vim.trim(prompt_text) .. ": ",
      }, function(input)
        local replacement = input or ""
        local new_line = line:gsub("%%TEXT%%", replacement)
        table.insert(final_lines, new_line)
        process_line(idx + 1)
      end)

    -- 3. Normal line, no placeholders
    else
      table.insert(final_lines, line)
      process_line(idx + 1)
    end
  end

  process_line(1)
end

function M.apply_template(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local filename = vim.fn.fnamemodify(filepath, ":t")
  
  -- Extract namespace: "1___Project.md" -> "1"
  local namespace = filename:match("^(.-)___")

  if namespace and namespace ~= "Templates" then
    local raw_content = get_template_content(namespace)
    if raw_content then
      process_placeholders(raw_content, function(processed_lines)
        -- Schedule the buffer update to avoid UI-lock collisions
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, processed_lines)
          end
        end)
      end)
    end
  end
end

return M