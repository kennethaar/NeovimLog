local M = {}
local todo_states = { "TODO", "WAITING", "DOING", "DONE", "CANCELLED" }

function M.cycle_todo()
  local parser = require("logseq.parser")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local parsed = parser.parse(lines)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local block = parser.block_at_line(parsed.blocks, lnum)
  
  if not block then return end
  local line = lines[block.line_start]
  local indent, rest = line:match("^(%s*)%- (.*)$")
  if not indent then return end

  local current_state, content_after = nil, rest

  for _, state in ipairs(todo_states) do
    local after = rest:match("^" .. state .. "%s*(.*)")
    if after then
      current_state, content_after = state, after
      break
    end
  end

  local next_state = nil
  if current_state then
    for i, state in ipairs(todo_states) do
      if state == current_state then
        next_state = todo_states[i + 1]
        break
      end
    end
  else
    next_state = todo_states[1]
  end

  local new_line = next_state and (indent .. "- " .. next_state .. " " .. content_after) 
                               or (indent .. "- " .. content_after)
  vim.api.nvim_buf_set_lines(0, block.line_start - 1, block.line_start, false, { new_line })
end

function M.setup_buf(bufnr)
  local opts = { buffer = bufnr, expr = true }

  -- Smart Bullet: Enter
  vim.keymap.set("i", "<CR>", function()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local indent = line:match("^(%s*)") or ""
    local is_at_end = (col >= #line)
    
    if line:match("id::") then
      return "<CR>" .. indent:sub(1, -3) .. "- "
    end
    
    local next_line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
    if is_at_end and next_line:match("^%s+id::") then
      return "<Down><End><CR>" .. indent .. "- "
    end
    
    return "<CR>" .. indent .. "- "
  end, vim.tbl_extend("force", opts, { desc = "Logseq Smart Bullet" }))

  -- Smart Property: Shift+Enter
  vim.keymap.set("i", "<S-CR>", function()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local indent = line:match("^(%s*)") or ""
    local is_at_end = (col >= #line)
    
    if line:match("id::") then return "<CR>" .. indent end
    
    local next_line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
    if is_at_end and line:match("^%s*%- ") and next_line:match("^%s+id::") then
      return "<Down><End><CR>" .. indent .. "  "
    end
    
    if line:match("^%s*%- ") then indent = indent .. "  " end
    return "<CR>" .. indent
  end, vim.tbl_extend("force", opts, { desc = "Logseq Smart Property" }))

  local map = vim.keymap.set
  map("n", "<C-t>", M.cycle_todo, { buffer = bufnr, desc = "Logseq: cycle TODO" })
  map("i", "<C-t>", function() M.cycle_todo(); vim.cmd("startinsert!") end, { buffer = bufnr })
  
  map("i", "<Tab>", "<C-t>", { buffer = bufnr })
  map("i", "<S-Tab>", "<C-d>", { buffer = bufnr })
  map("n", "<Tab>", ">>", { buffer = bufnr })
  map("n", "<S-Tab>", "<<", { buffer = bufnr })

  vim.bo[bufnr].shiftwidth = 2
  vim.bo[bufnr].tabstop = 2
  vim.bo[bufnr].expandtab = true
  vim.bo[bufnr].softtabstop = 2
end

return M