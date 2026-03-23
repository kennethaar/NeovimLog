--- logseq.nvim namespace tree view
--- Auto-displays a clickable tree of all pages in the same namespace at the
--- bottom of the buffer whenever the current file belongs to a namespace.
--- The tree section is purely read-only: it is never saved to disk and all
--- edits within it are blocked via the buffer's 'modifiable' flag.

local config = require("logseq.config")
local util   = require("logseq.util")

local M = {}

local HEADER_PREFIX  = "── Namespace: "
local HEADER_PATTERN = "^── Namespace: .* ──$"
local SEPARATOR      = ""

-- ── State (one table per buffer, audit #21) ───────────────────────────

M._state = {} -- bufnr → { visible, region, source_map, _had_tree }

local function get_state(bufnr)
  if not M._state[bufnr] then
    M._state[bufnr] = { visible = false, region = nil, source_map = nil, _had_tree = false }
  end
  return M._state[bufnr]
end

-- ── Helpers ───────────────────────────────────────────────────────────

local function get_page_name(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return nil end
  local ok, indexer = pcall(require, "logseq.indexer")
  if not ok then return nil end
  return indexer.page_name_from_file(filepath)
end

--- Return the top-level namespace segment for a page name, or nil.
--- "BJJ/Techniques/Triangle" → "BJJ"
--- "daily notes" → nil  (no namespace)
local function get_ns_root(page_name)
  return page_name:match("^([^/]+)/")
end

function M.in_region(bufnr, lnum)
  local state = get_state(bufnr)
  if not state.region then return false end
  return lnum >= state.region.start_line and lnum <= state.region.end_line
end

local function find_header_line(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match(HEADER_PATTERN) then return i end
  end
  return nil
end

--- Properly reset the modified flag without triggering autocmds.
local function clear_modified(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("noautocmd setlocal nomodified")
  end)
end

--- Set buf modifiable flag. Used to lock/unlock the tree region.
local function set_modifiable(bufnr, value)
  if vim.bo[bufnr].modifiable ~= value then
    vim.bo[bufnr].modifiable = value
  end
end

--- Lock or unlock editing based on whether the cursor is inside the tree.
local function update_modifiable(bufnr)
  local state = get_state(bufnr)
  if not state.visible or not state.region then
    set_modifiable(bufnr, true)
    return
  end
  local ok, pos = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok then return end
  set_modifiable(bufnr, pos[1] < state.region.start_line)
end

-- ── Page Scanner ──────────────────────────────────────────────────────

--- Collect all pages whose name starts with ns_root or equals ns_root.
local function scan_namespace_pages(ns_root, vault)
  local pages_dir = vault .. "/pages"
  if vim.fn.isdirectory(pages_dir) == 0 then return {} end

  local files = vim.fn.glob(pages_dir .. "/*.md", true, true)
  local pages = {}
  local prefix = ns_root .. "/"

  for _, filepath in ipairs(files) do
    local filename = vim.fn.fnamemodify(filepath, ":t")
    local page_name = util.decode_filename(filename)
    if page_name == ns_root or page_name:sub(1, #prefix) == prefix then
      table.insert(pages, { name = page_name, file = filepath })
    end
  end

  table.sort(pages, function(a, b) return a.name < b.name end)
  return pages
end

-- ── Tree Builder ──────────────────────────────────────────────────────

--- Parse a page list into a nested tree.
--- Returns a root node: { children = { [label] = node, ... } }
--- Each leaf node: { label, _file, _name, children, _order }
local function build_tree(pages)
  local root = { children = {}, _order = {} }

  for _, page in ipairs(pages) do
    local parts = {}
    for part in page.name:gmatch("[^/]+") do
      table.insert(parts, part)
    end

    local node = root
    for i, part in ipairs(parts) do
      if not node.children[part] then
        node.children[part] = { label = part, children = {}, _file = nil, _name = nil, _order = {} }
        table.insert(node._order, part)
      end
      if i == #parts then
        node.children[part]._file = page.file
        node.children[part]._name = page.name
      end
      node = node.children[part]
    end
  end

  return root
end

--- Recursively render tree nodes to display lines.
--- display: string[], smap: { [rel_idx] = { file, line } }
--- prefix_parts: list of indent strings accumulated from parent levels
local function render_node(node, current_page, display, smap, prefix_parts)
  local keys = node._order or {}

  for idx, key in ipairs(keys) do
    local child   = node.children[key]
    local is_last = (idx == #keys)

    local connector = is_last and "└── " or "├── "
    local child_pfx = is_last and "    " or "│   "

    local indent     = table.concat(prefix_parts, "")
    local is_current = (child._name == current_page)
    local label      = child.label .. (is_current and " ←" or "")
    local line       = indent .. connector .. label

    table.insert(display, line)
    if child._file then
      smap[#display] = { file = child._file, line = 1 }
    end

    local next_pfx = {}
    for _, p in ipairs(prefix_parts) do table.insert(next_pfx, p) end
    table.insert(next_pfx, child_pfx)
    render_node(child, current_page, display, smap, next_pfx)
  end
end

-- ── Display Builder ───────────────────────────────────────────────────

local function build_display(pages, ns_root, current_page)
  local display = {}
  local smap    = {}

  table.insert(display, HEADER_PREFIX .. ns_root .. " ──")

  local tree = build_tree(pages)
  render_node(tree, current_page, display, smap, {})

  return display, smap
end

-- ── Rendering ─────────────────────────────────────────────────────────

function M.render_section(bufnr)
  local page_name = get_page_name(bufnr)
  if not page_name then return end

  local ns_root = get_ns_root(page_name)
  if not ns_root then return end

  local vault = config.current.vault_path
  if not vault or vault == "" then return end

  local pages = scan_namespace_pages(ns_root, vault)
  if #pages == 0 then return end

  local display_lines, smap = build_display(pages, ns_root, page_name)

  local state         = get_state(bufnr)
  local line_count    = vim.api.nvim_buf_line_count(bufnr)
  local section_start = line_count + 1

  local final_lines = { SEPARATOR }
  vim.list_extend(final_lines, display_lines)

  -- Ensure writable while we mutate, then lock + clear modified
  set_modifiable(bufnr, true)
  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, final_lines)
  clear_modified(bufnr)

  state.region     = { start_line = section_start, end_line = section_start + #final_lines - 1 }
  state.visible    = true
  state.source_map = {}

  for rel_line, info in pairs(smap) do
    state.source_map[section_start + rel_line] = info
  end

  -- Lock editing in the tree region based on current cursor position
  update_modifiable(bufnr)

  -- Highlights
  local ns = vim.api.nvim_create_namespace("logseq_ns_tree")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  -- Header line is display[1] → buffer line section_start + 1 (0-indexed: section_start)
  vim.api.nvim_buf_add_highlight(bufnr, ns, "Title", section_start, 0, -1)

  for abs_line, _ in pairs(state.source_map) do
    local line_0 = abs_line - 1
    local txt    = vim.api.nvim_buf_get_lines(bufnr, line_0, line_0 + 1, false)[1] or ""
    if txt:match(" ←$") then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "Bold", line_0, 0, -1)
    else
      vim.api.nvim_buf_add_highlight(bufnr, ns, "LogseqLink", line_0, 0, -1)
    end
  end
end

function M.remove_section(bufnr)
  local state = get_state(bufnr)
  local header_line = find_header_line(bufnr)
  if not header_line then
    state.visible    = false
    state.region     = nil
    state.source_map = nil
    set_modifiable(bufnr, true)
    return false
  end

  local start = header_line
  if header_line > 1 then
    local maybe_sep = vim.api.nvim_buf_get_lines(bufnr, header_line - 2, header_line - 1, false)[1]
    if maybe_sep and maybe_sep:match("^%s*$") then start = header_line - 1 end
  end

  -- Must be writable to remove lines; preserve modified state of real content
  set_modifiable(bufnr, true)
  local was_modified = vim.bo[bufnr].modified
  vim.api.nvim_buf_set_lines(bufnr, start - 1, vim.api.nvim_buf_line_count(bufnr), false, {})
  if not was_modified then clear_modified(bufnr) end

  state.visible    = false
  state.region     = nil
  state.source_map = nil
  vim.api.nvim_buf_clear_namespace(bufnr, vim.api.nvim_create_namespace("logseq_ns_tree"), 0, -1)
  return true
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = get_state(bufnr)
  if state.visible then M.remove_section(bufnr) else M.render_section(bufnr) end
end

-- ── Navigation ────────────────────────────────────────────────────────

function M.navigate()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum  = vim.api.nvim_win_get_cursor(0)[1]

  if not M.in_region(bufnr, lnum) then return false end
  local state = get_state(bufnr)
  if not state.source_map or not state.source_map[lnum] then return false end

  local target = state.source_map[lnum]
  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(target.file))
  if target.line and target.line > 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, { target.line, 0 })
  end
  return true
end

-- ── Buffer Setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local km         = config.current.keymaps or {}
  local toggle_key = km.toggle_ns_tree or "<leader>N"

  vim.keymap.set("n", toggle_key, M.toggle, { buffer = bufnr, silent = true, desc = "Logseq: toggle namespace tree" })

  local group = vim.api.nvim_create_augroup("LogseqNsTree_" .. bufnr, { clear = true })

  -- Lock / unlock based on cursor position (blocks dd, x, r, etc. in tree)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group, buffer = bufnr,
    callback = function(ev) update_modifiable(ev.buf) end,
  })

  -- Friendly message when trying to enter insert mode inside the tree
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group, buffer = bufnr,
    callback = function(ev)
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      if M.in_region(ev.buf, lnum) then
        vim.cmd("stopinsert")
        vim.notify("[logseq.nvim] Namespace tree is read-only.", vim.log.levels.INFO)
      end
    end,
  })

  -- Strip tree before write so it is never saved to disk
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group, buffer = bufnr,
    callback = function(ev)
      local state = get_state(ev.buf)
      if state.visible then
        state._had_tree = true
        M.remove_section(ev.buf)   -- also sets modifiable=true
      end
    end,
  })

  -- Restore tree after write
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group, buffer = bufnr,
    callback = function(ev)
      local state = get_state(ev.buf)
      if state._had_tree then
        state._had_tree = false
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then M.render_section(ev.buf) end
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group, buffer = bufnr,
    callback = function(ev)
      set_modifiable(ev.buf, true)  -- safety: restore on unload
      M._state[ev.buf] = nil
    end,
  })

  -- Auto-show when the page is namespaced
  local page_name = get_page_name(bufnr)
  if page_name and get_ns_root(page_name) then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.render_section(bufnr)
      end
    end)
  end
end

return M
