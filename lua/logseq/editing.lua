local M = {}
local todo_states = { "TODO", "WAITING", "DOING", "DONE", "CANCELLED" }

-- ── Cursor Snapping ──────────────────────────────────────────────────
-- After vertical movement, snap cursor to just after "- " on bullet lines.
-- Horizontal movement (h/l/arrows) is unrestricted.

local _snapping = false

local function snap_to_bullet()
  if _snapping then return end
  local line = vim.api.nvim_get_current_line()
  local prefix = line:match("^(%s*%- )")
  if not prefix then return end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  if col < #prefix then
    _snapping = true
    vim.api.nvim_win_set_cursor(0, { row, #prefix })
    _snapping = false
  end
end

-- ── Region Guards ────────────────────────────────────────────────────
-- Shared check for backlinks (read-only) and queries (non-task lines).
-- Returns true if the cursor is in a protected region and the caller
-- should abort its action.

local function in_protected_region(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  local bl_ok, backlinks = pcall(require, "logseq.backlinks")
  if bl_ok and backlinks.in_region(bufnr, lnum) then
    return true
  end

  local q_ok, queries = pcall(require, "logseq.queries")
  if q_ok and queries.in_region(bufnr, lnum) then
    return true
  end

  return false
end

-- ── TODO Cycling ─────────────────────────────────────────────────────

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

-- ── Buffer Setup ─────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local parser = require("logseq.parser")
  local map = vim.keymap.set

  -- ── Smart Enter (Insert Mode) ────────────────────────────────────
  -- Works like 'o': uses the parser to find block.line_end and inserts
  -- a new sibling AFTER all children. Handles text splitting mid-line
  -- and completion popup confirmation.
  map("i", "<CR>", function()
    if in_protected_region(bufnr) then
      vim.cmd("stopinsert")
      return
    end

    -- Completion popup open → confirm selection, done
    if vim.fn.pumvisible() == 1 then
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<C-y>", true, false, true), "n", true)
      return
    end

    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()

    -- Parse buffer to locate the current block
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local parsed = parser.parse(lines)
    local block = parser.block_at_line(parsed.blocks, row)

    local indent = 0
    local insert_after = row

    if block then
      indent = block.indent
      insert_after = block.line_end
    end

    local indent_str = string.rep(" ", indent)

    -- Text splitting: if cursor is mid-content, move trailing text to new block
    local text_after = ""
    local bullet_prefix = line:match("^(%s*%- )")
    if bullet_prefix and col > #bullet_prefix - 1 and col < #line then
      text_after = line:sub(col + 1)
      vim.api.nvim_set_current_line(line:sub(1, col))
      -- Buffer changed — re-parse to get correct line_end
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      parsed = parser.parse(lines)
      block = parser.block_at_line(parsed.blocks, row)
      if block then insert_after = block.line_end end
    end

    -- Insert the new sibling line
    local new_line = indent_str .. "- " .. text_after
    vim.api.nvim_buf_set_lines(0, insert_after, insert_after, false, { new_line })

    -- Place cursor right after "- "
    vim.api.nvim_win_set_cursor(0, { insert_after + 1, #indent_str + 2 })
  end, { buffer = bufnr, desc = "Logseq: new sibling (insert)" })

  -- ── Smart Property: Shift+Enter ──────────────────────────────────
  -- Drops to a continuation/property line (no bullet), indented under the block.
  map("i", "<S-CR>", function()
    if in_protected_region(bufnr) then
      vim.cmd("stopinsert")
      return
    end

    local row = vim.api.nvim_win_get_cursor(0)[1]

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local parsed = parser.parse(lines)
    local block = parser.block_at_line(parsed.blocks, row)

    local indent = 0
    local insert_after = row

    if block then
      indent = block.indent + 2  -- property indent = parent + 2
      -- Insert right after the bullet + its properties, but before children
      -- Walk from block.line_start + 1 to find first child or end
      insert_after = block.line_start
      for i = block.line_start + 1, block.line_end do
        local l = lines[i]
        -- If it's a child bullet, stop before it
        if l:match("^%s*%- ") then break end
        insert_after = i
      end
    end

    local indent_str = string.rep(" ", indent)
    vim.api.nvim_buf_set_lines(0, insert_after, insert_after, false, { indent_str })
    vim.api.nvim_win_set_cursor(0, { insert_after + 1, #indent_str })
  end, { buffer = bufnr, desc = "Logseq: new property line" })

  -- ── O: New Sibling Above (Normal Mode) ───────────────────────────
  map("n", "O", function()
    if in_protected_region(bufnr) then return end

    local row = vim.api.nvim_win_get_cursor(0)[1]
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local parsed = parser.parse(lines)
    local block = parser.block_at_line(parsed.blocks, row)

    local indent = 0
    local insert_before = row

    if block then
      indent = block.indent
      insert_before = block.line_start
    end

    local new_line = string.rep(" ", indent) .. "- "
    vim.api.nvim_buf_set_lines(0, insert_before - 1, insert_before - 1, false, { new_line })
    vim.api.nvim_win_set_cursor(0, { insert_before, #new_line })
    vim.cmd("startinsert!")
  end, { buffer = bufnr, desc = "Logseq: new sibling above" })

  -- ── o: Guard for motions.new_sibling ─────────────────────────────
  -- motions.lua maps o → new_sibling before us, so we override with a
  -- guarded wrapper that delegates to motions when outside regions.
  local motions_ok, motions = pcall(require, "logseq.motions")
  if motions_ok and motions.new_sibling then
    map("n", require("logseq.config").current.keymaps.new_sibling, function()
      if in_protected_region(bufnr) then return end
      motions.new_sibling()
    end, { buffer = bufnr, silent = true, desc = "Logseq: new sibling (guarded)" })
  end

  -- ── Vertical Movement Snapping (Normal Mode) ─────────────────────
  -- j/k and Up/Down place cursor after "- " on bullet lines.
  -- Respects counts (e.g. 5j).
  for _, key in ipairs({ "j", "<Down>" }) do
    map("n", key, function()
      vim.cmd("normal! " .. vim.v.count1 .. "j")
      snap_to_bullet()
    end, { buffer = bufnr, silent = true, desc = "Logseq: down + snap" })
  end

  for _, key in ipairs({ "k", "<Up>" }) do
    map("n", key, function()
      vim.cmd("normal! " .. vim.v.count1 .. "k")
      snap_to_bullet()
    end, { buffer = bufnr, silent = true, desc = "Logseq: up + snap" })
  end

  -- ── Vertical Movement Snapping (Insert Mode) ─────────────────────
  -- Fires on any line change in insert mode (Up/Down arrows, mouse, etc.)
  local last_insert_row = nil
  local group = vim.api.nvim_create_augroup("LogseqSnap_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = group,
    buffer = bufnr,
    callback = function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if last_insert_row and row ~= last_insert_row then
        vim.schedule(snap_to_bullet)
      end
      last_insert_row = row
    end,
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      last_insert_row = vim.api.nvim_win_get_cursor(0)[1]
    end,
  })

  -- ── TODO Cycling ─────────────────────────────────────────────────
  map("n", "<C-t>", M.cycle_todo, { buffer = bufnr, desc = "Logseq: cycle TODO" })
  map("i", "<C-t>", function() M.cycle_todo(); vim.cmd("startinsert!") end, { buffer = bufnr })

  -- ── Tab Indent/Outdent ───────────────────────────────────────────
  map("i", "<Tab>", "<C-t>", { buffer = bufnr })
  map("i", "<S-Tab>", "<C-d>", { buffer = bufnr })
  map("n", "<Tab>", ">>", { buffer = bufnr })
  map("n", "<S-Tab>", "<<", { buffer = bufnr })

  -- ── Buffer Options ───────────────────────────────────────────────
  vim.bo[bufnr].shiftwidth = 2
  vim.bo[bufnr].tabstop = 2
  vim.bo[bufnr].expandtab = true
  vim.bo[bufnr].softtabstop = 2
end

return M
