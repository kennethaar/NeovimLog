--- logseq.nvim link following
--- Resolves [[wikilinks]], ((block-refs)), and #tags under the cursor.
--- Only activates when cursor is inside the link delimiters.

local config = require("logseq.config")
local util = require("logseq.util")

local M = {}

--- Encode a page name to its on-disk filename.
--- Delegates to shared util (audit #29).
---@param page_name string
---@return string
function M.page_to_filename(page_name)
  return util.encode_filename(page_name)
end

--- Decode a filename back to a page name.
--- Delegates to shared util with percent-decode support (audit #29).
---@param filename string
---@return string
function M.filename_to_page(filename)
  return util.decode_filename(filename)
end

--- Detect the link element under the cursor. Returns nil if cursor is not inside any link.
---@return string|nil type   "link" | "block_ref" | "tag"
---@return string|nil value  page name, block uuid, or tag name
function M.link_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  -- Check [[wikilinks]]
  local pos = 1
  while true do
    local s, e, content = line:find("%[%[(.-)%]%]", pos)
    if not s then break end
    if col >= s and col <= e then return "link", content end
    pos = e + 1
  end

  -- Check ((block-refs))
  pos = 1
  while true do
    local s, e, content = line:find("%(%((.-)%)%)", pos)
    if not s then break end
    if col >= s and col <= e then return "block_ref", content end
    pos = e + 1
  end

  -- Check #tags (but not inside [[...]])
  pos = 1
  while true do
    local s, e, tag = line:find("#([%w_%-/]+)", pos)
    if not s then break end
    if col >= s and col <= e then
      local before = line:sub(1, s - 1)
      local opens = select(2, before:gsub("%[%[", ""))
      local closes = select(2, before:gsub("%]%]", ""))
      if opens <= closes then return "tag", tag end
    end
    pos = e + 1
  end

  return nil, nil
end

--- Open a page file, prompting to create if it doesn't exist.
---@param filepath string
---@param display_name string
local function open_or_create(filepath, display_name)
  if vim.fn.filereadable(filepath) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    return
  end

  vim.ui.select({ "Create page", "Cancel" }, {
    prompt = '"' .. display_name .. '" not found. Create it?',
  }, function(choice)
    if choice ~= "Create page" then return end
    local dir = vim.fn.fnamemodify(filepath, ":h")
    if vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, "p")
    end
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
  end)
end

--- Follow a [[wikilink]] — tries pages/ then journals/, creates if missing.
local function follow_wikilink(vault, value)
  local filepath = vault .. "/pages/" .. M.page_to_filename(value)
  if vim.fn.filereadable(filepath) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    return
  end

  local journal_dir = vault .. "/journals"
  if vim.fn.isdirectory(journal_dir) == 1 then
    local tried = {}
    for _, name in ipairs({ value .. ".md", value:gsub("%-", "_") .. ".md", value:gsub("_", "-") .. ".md" }) do
      if not tried[name] then
        tried[name] = true
        local p = journal_dir .. "/" .. name
        if vim.fn.filereadable(p) == 1 then
          vim.cmd("edit " .. vim.fn.fnameescape(p))
          return
        end
      end
    end

    local digits = value:gsub("[^%d]", "")
    if #digits >= 8 then
      local matches = vim.fn.glob(journal_dir
        .. "/*" .. digits:sub(1,4) .. "*" .. digits:sub(5,6) .. "*" .. digits:sub(7,8) .. "*.md", true, true)
      if #matches == 1 then
        vim.cmd("edit " .. vim.fn.fnameescape(matches[1]))
        return
      end
    end
  end

  open_or_create(filepath, value)
end

--- Follow a ((block-ref)) by grepping the vault for `id:: <uuid>`.
local function follow_block_ref(vault, value)
  local search_dirs = {}
  if vim.fn.isdirectory(vault .. "/pages")   == 1 then search_dirs[#search_dirs+1] = vault .. "/pages"   end
  if vim.fn.isdirectory(vault .. "/journals") == 1 then search_dirs[#search_dirs+1] = vault .. "/journals" end

  if #search_dirs == 0 then
    vim.notify("No pages/ or journals/ found in vault", vim.log.levels.WARN)
    return
  end

  local cmd = { "grep", "-rn", "--include=*.md", "id:: " .. value }
  vim.list_extend(cmd, search_dirs)
  local results = vim.fn.systemlist(cmd)

  if vim.v.shell_error ~= 0 or #results == 0 then
    vim.notify("Block ref not found: " .. value, vim.log.levels.WARN)
    return
  end

  local fp, lnum_str = results[1]:match("^(.+):(%d+):")
  if not fp then return end
  local lnum = tonumber(lnum_str) or 1
  vim.cmd("edit " .. vim.fn.fnameescape(fp))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
end

--- Follow a #tag by opening its page file.
local function follow_tag(vault, value)
  local filepath = vault .. "/pages/" .. M.page_to_filename(value)
  open_or_create(filepath, value)
end

--- Follow the link under the cursor.
function M.follow()
  local bufnr = vim.api.nvim_get_current_buf()
  local row   = vim.api.nvim_win_get_cursor(0)[1]

  local bl_ok, backlinks = pcall(require, "logseq.backlinks")
  if bl_ok and backlinks.in_region(bufnr, row) and backlinks.navigate() then return end

  local q_ok, queries = pcall(require, "logseq.queries")
  if q_ok and queries.in_region(bufnr, row) and not M.link_under_cursor() then
    if queries.navigate() then return end
  end

  local nt_ok, ns_tree = pcall(require, "logseq.namespace_tree")
  if nt_ok and ns_tree.in_region(bufnr, row) and ns_tree.navigate() then return end

  local link_type, value = M.link_under_cursor()

  if not link_type then
    local key = config.current.keymaps.follow_link
    pcall(vim.cmd, "normal! " .. (key == "<CR>" and "j" or key))
    return
  end

  local vault = config.current.vault_path
  if     link_type == "link"      then follow_wikilink(vault, value)
  elseif link_type == "block_ref" then follow_block_ref(vault, value)
  elseif link_type == "tag"       then follow_tag(vault, value)
  end
end

--- Wrap the visual selection in [[...]].
function M.wrap_link()
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")

  if start_pos[2] > end_pos[2] or (start_pos[2] == end_pos[2] and start_pos[3] > end_pos[3]) then
    start_pos, end_pos = end_pos, start_pos
  end

  if start_pos[2] ~= end_pos[2] then
    vim.notify("Link wrapping only works on single-line selections", vim.log.levels.WARN)
    return
  end

  local lnum = start_pos[2]
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
  local col_start = start_pos[3] - 1
  local col_end = end_pos[3] - 1

  local before = line:sub(1, col_start)
  local selected = line:sub(col_start + 1, col_end + 1)
  local after = line:sub(col_end + 2)

  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "x", false)

  -- Toggle: unwrap if already wrapped
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
