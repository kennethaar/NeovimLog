--- logseq.nvim link following
--- Resolves [[wikilinks]], ((block-refs)), and #tags under the cursor.
--- Only activates when cursor is inside the link delimiters (not between links).

local config = require("logseq.config")

local M = {}

--- Encode a page name to its on-disk filename.
--- "BJJ/Techniques/Triangle" → "BJJ___Techniques___Triangle.md"
---@param page_name string
---@return string
function M.page_to_filename(page_name)
  return page_name:gsub("/", "___") .. ".md"
end

--- Decode a filename back to a page name.
--- "BJJ___Techniques___Triangle.md" → "BJJ/Techniques/Triangle"
---@param filename string
---@return string
function M.filename_to_page(filename)
  return filename:gsub("%.md$", ""):gsub("___", "/")
end

--- Detect the link element under the cursor. Returns nil if cursor is not inside any link.
---@return string|nil type   "link" | "block_ref" | "tag"
---@return string|nil value  page name, block uuid, or tag name
function M.link_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1 -- convert 0-indexed to 1-indexed

  -- Check [[wikilinks]]
  local pos = 1
  while true do
    local s, e, content = line:find("%[%[(.-)%]%]", pos)
    if not s then break end
    if col >= s and col <= e then
      return "link", content
    end
    pos = e + 1
  end

  -- Check ((block-refs))
  pos = 1
  while true do
    local s, e, content = line:find("%(%((.-)%)%)", pos)
    if not s then break end
    if col >= s and col <= e then
      return "block_ref", content
    end
    pos = e + 1
  end

  -- Check #tags (but not inside [[...]])
  pos = 1
  while true do
    local s, e, tag = line:find("#([%w_%-/]+)", pos)
    if not s then break end
    if col >= s and col <= e then
      -- Verify we're not inside a wikilink
      local before = line:sub(1, s - 1)
      local opens = select(2, before:gsub("%[%[", ""))
      local closes = select(2, before:gsub("%]%]", ""))
      if opens <= closes then
        return "tag", tag
      end
    end
    pos = e + 1
  end

  return nil, nil
end

--- Open a page file, prompting to create if it doesn't exist.
---@param filepath string  full path to the .md file
---@param display_name string  the page name for display in the prompt
local function open_or_create(filepath, display_name)
  if vim.fn.filereadable(filepath) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    return
  end

  vim.ui.select({ "Create page", "Cancel" }, {
    prompt = '"' .. display_name .. '" not found. Create it?',
  }, function(choice)
    if choice == "Create page" then
      -- Ensure parent directory exists
      local dir = vim.fn.fnamemodify(filepath, ":h")
      if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
      end
      vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    end
  end)
end

--- Follow the link under the cursor.
function M.follow()
  local link_type, value = M.link_under_cursor()

  if not link_type then
    -- No link found — execute the default behavior of the mapped key
    local key = config.current.keymaps.follow_link
    if key == "<CR>" then
      vim.cmd("normal! j")
    else
      pcall(vim.cmd, "normal! " .. key)
    end
    return
  end

  local vault = config.current.vault_path

  if link_type == "link" then
    local filename = M.page_to_filename(value)
    local filepath = vault .. "/pages/" .. filename

    -- Also try journals (users sometimes link dates)
    if vim.fn.filereadable(filepath) == 0 then
      local journal_name = value:gsub("%-", "_") .. ".md"
      local journal_path = vault .. "/journals/" .. journal_name
      if vim.fn.filereadable(journal_path) == 1 then
        vim.cmd("edit " .. vim.fn.fnameescape(journal_path))
        return
      end
    end

    open_or_create(filepath, value)

  elseif link_type == "block_ref" then
    local pattern = "id:: " .. value
    -- Search pages/ and journals/ for the block id
    local search_dirs = {}
    local pages_dir = vault .. "/pages"
    local journals_dir = vault .. "/journals"
    if vim.fn.isdirectory(pages_dir) == 1 then search_dirs[#search_dirs + 1] = pages_dir end
    if vim.fn.isdirectory(journals_dir) == 1 then search_dirs[#search_dirs + 1] = journals_dir end

    if #search_dirs == 0 then
      vim.notify("No pages/ or journals/ found in vault", vim.log.levels.WARN)
      return
    end

    local cmd = { "grep", "-rn", "--include=*.md", pattern }
    vim.list_extend(cmd, search_dirs)
    local results = vim.fn.systemlist(cmd)

    if #results == 0 then
      vim.notify("Block ref not found: " .. value, vim.log.levels.WARN)
      return
    end

    -- Parse first result: "filepath:linenum:id:: uuid"
    local filepath, lnum_str = results[1]:match("^(.+):(%d+):")
    if filepath and lnum_str then
      local lnum = tonumber(lnum_str)
      vim.cmd("edit " .. vim.fn.fnameescape(filepath))
      if lnum and lnum > 1 then
        -- Jump to the bullet line (one above the id:: property)
        vim.api.nvim_win_set_cursor(0, { lnum - 1, 0 })
      elseif lnum then
        vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      end
    end

  elseif link_type == "tag" then
    local filename = M.page_to_filename(value)
    local filepath = vault .. "/pages/" .. filename
    open_or_create(filepath, value)
  end
end

--- Wrap the visual selection in [[...]].
function M.wrap_link()
  -- Get selection range (works in visual mode callback)
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")

  -- Ensure start is before end
  if start_pos[2] > end_pos[2] or (start_pos[2] == end_pos[2] and start_pos[3] > end_pos[3]) then
    start_pos, end_pos = end_pos, start_pos
  end

  -- Only single-line selections
  if start_pos[2] ~= end_pos[2] then
    vim.notify("Link wrapping only works on single-line selections", vim.log.levels.WARN)
    return
  end

  local lnum = start_pos[2]
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
  local col_start = start_pos[3] - 1  -- 0-indexed
  local col_end = end_pos[3] - 1      -- 0-indexed, inclusive

  local before = line:sub(1, col_start)
  local selected = line:sub(col_start + 1, col_end + 1)
  local after = line:sub(col_end + 2)

  -- Exit visual mode
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "x", false)

  -- Check if already wrapped — toggle off
  if before:sub(-2) == "[[" and after:sub(1, 2) == "]]" then
    local new_line = before:sub(1, -3) .. selected .. after:sub(3)
    vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { new_line })
  else
    local new_line = before .. "[[" .. selected .. "]]" .. after
    vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { new_line })
  end
end

--- Bind link following for the current buffer.
function M.setup_buf()
  local km = config.current.keymaps
  vim.keymap.set("n", km.follow_link, M.follow, {
    buffer = true,
    silent = true,
    desc = "Logseq: follow link",
  })
  vim.keymap.set("v", km.follow_link, M.wrap_link, {
    buffer = true,
    silent = true,
    desc = "Logseq: wrap selection in [[link]]",
  })
end

return M