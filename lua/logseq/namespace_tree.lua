--- logseq.nvim namespace tree view
--- Auto-displays a clickable tree of all pages in the same namespace at the
--- bottom of the buffer.  The section is read-only and is never saved to disk.

local config = require("logseq.config")
local util   = require("logseq.util")

local M = {}

local HEADER_PREFIX  = "── Namespace: "
local HEADER_PATTERN = "^── Namespace: .* ──$"
local SEPARATOR      = ""

-- ── State ─────────────────────────────────────────────────────────────

M._state = {}

local function get_state(bufnr)
  if not M._state[bufnr] then
    M._state[bufnr] = { visible = false, region = nil, source_map = nil, _had_tree = false }
  end
  return M._state[bufnr]
end

-- ── Low-level helpers ─────────────────────────────────────────────────

local function get_page_name(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return nil end
  local ok, indexer = pcall(require, "logseq.indexer")
  if not ok then return nil end
  return indexer.page_name_from_file(filepath)
end

local function get_ns_root(page_name)
  return page_name:match("^([^/]+)/")
end

function M.in_region(bufnr, lnum)
  local r = get_state(bufnr).region
  return r ~= nil and lnum >= r.start_line and lnum <= r.end_line
end

--- Return the 1-indexed line of the tree header, or nil.
local function find_header_line(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match(HEADER_PATTERN) then return i end
  end
end

--- Compute {start_line, end_line} for an already-present tree header.
--- start_line backs up one line when the preceding line is a blank separator.
local function region_from_header(bufnr, header_line)
  local start_line = header_line
  if header_line > 1 then
    local sep = vim.api.nvim_buf_get_lines(bufnr, header_line - 2, header_line - 1, false)[1]
    if sep and sep:match("^%s*$") then
      start_line = header_line - 1
    end
  end
  return { start_line = start_line, end_line = vim.api.nvim_buf_line_count(bufnr) }
end

local function clear_modified(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("noautocmd setlocal nomodified")
  end)
end

--- Lock the buffer when the cursor is inside the tree; unlock it otherwise.
local function update_modifiable(bufnr)
  local state = get_state(bufnr)
  if not (state.visible and state.region) then
    vim.bo[bufnr].modifiable = true
    return
  end
  local ok, pos = pcall(vim.api.nvim_win_get_cursor, 0)
  vim.bo[bufnr].modifiable = not ok or pos[1] < state.region.start_line
end

-- ── Page scanner ──────────────────────────────────────────────────────

local function scan_namespace_pages(ns_root, vault)
  local pages_dir = vault .. "/pages"
  if vim.fn.isdirectory(pages_dir) == 0 then return {} end

  local prefix = ns_root .. "/"
  local pages  = {}

  for _, filepath in ipairs(vim.fn.glob(pages_dir .. "/*.md", true, true)) do
    local page_name = util.decode_filename(vim.fn.fnamemodify(filepath, ":t"))
    if page_name == ns_root or page_name:sub(1, #prefix) == prefix then
      table.insert(pages, { name = page_name, file = filepath })
    end
  end

  table.sort(pages, function(a, b) return a.name < b.name end)
  return pages
end

-- ── Tree builder ──────────────────────────────────────────────────────

local function build_tree(pages)
  local root = { children = {}, _order = {} }
  for _, page in ipairs(pages) do
    local node = root
    local parts = {}
    for part in page.name:gmatch("[^/]+") do parts[#parts + 1] = part end
    for i, part in ipairs(parts) do
      if not node.children[part] then
        node.children[part] = { label = part, children = {}, _file = nil, _name = nil, _order = {} }
        node._order[#node._order + 1] = part
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

local function render_node(node, current_page, display, smap, prefix)
  for idx, key in ipairs(node._order) do
    local child     = node.children[key]
    local is_last   = idx == #node._order
    local connector = is_last and "└── " or "├── "
    local child_pfx = is_last and "    " or "│   "
    local marker    = child._name == current_page and " ←" or ""

    display[#display + 1] = table.concat(prefix) .. connector .. child.label .. marker
    if child._file then smap[#display] = { file = child._file, line = 1 } end

    local next_prefix = vim.list_extend(vim.list_extend({}, prefix), { child_pfx })
    render_node(child, current_page, display, smap, next_prefix)
  end
end

local function build_display(pages, ns_root, current_page)
  local display = { HEADER_PREFIX .. ns_root .. " ──" }
  local smap    = {}
  render_node(build_tree(pages), current_page, display, smap, {})
  return display, smap
end

-- ── Section management ────────────────────────────────────────────────

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
  local state               = get_state(bufnr)
  local line_count          = vim.api.nvim_buf_line_count(bufnr)
  local section_start       = line_count + 1
  local final_lines         = vim.list_extend({ SEPARATOR }, display_lines)

  -- state.visible is false here: any TextChanged fired during set_lines is ignored
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, final_lines)
  clear_modified(bufnr)

  state.region     = { start_line = section_start, end_line = section_start + #final_lines - 1 }
  state.visible    = true
  state.source_map = {}
  for rel, info in pairs(smap) do
    state.source_map[section_start + rel] = info
  end

  update_modifiable(bufnr)

  local ns = vim.api.nvim_create_namespace("logseq_ns_tree")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(bufnr, ns, "Title", section_start, 0, -1)
  for abs_line in pairs(state.source_map) do
    local line_0 = abs_line - 1
    local txt    = vim.api.nvim_buf_get_lines(bufnr, line_0, line_0 + 1, false)[1] or ""
    local hl     = txt:match(" ←$") and "Bold" or "LogseqLink"
    vim.api.nvim_buf_add_highlight(bufnr, ns, hl, line_0, 0, -1)
  end
end

function M.remove_section(bufnr)
  local state = get_state(bufnr)
  vim.bo[bufnr].modifiable = true

  local header = find_header_line(bufnr)
  if not header then
    state.visible    = false
    state.region     = nil
    state.source_map = nil
    return false
  end

  local region       = region_from_header(bufnr, header)
  local was_modified = vim.bo[bufnr].modified
  -- state.visible is still true here: TextChanged will see no header and return early
  vim.api.nvim_buf_set_lines(bufnr, region.start_line - 1, vim.api.nvim_buf_line_count(bufnr), false, {})
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
  local bufnr  = vim.api.nvim_get_current_buf()
  local lnum   = vim.api.nvim_win_get_cursor(0)[1]
  if not M.in_region(bufnr, lnum) then return false end

  local smap   = get_state(bufnr).source_map
  local target = smap and smap[lnum]
  if not target then return false end

  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(target.file))
  pcall(vim.api.nvim_win_set_cursor, 0, { target.line, 0 })
  return true
end

-- ── Buffer setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local km         = config.current.keymaps or {}
  local toggle_key = km.toggle_ns_tree or "<leader>N"
  vim.keymap.set("n", toggle_key, M.toggle,
    { buffer = bufnr, silent = true, desc = "Logseq: toggle namespace tree" })

  local group = vim.api.nvim_create_augroup("LogseqNsTree_" .. bufnr, { clear = true })

  -- Toggle modifiable as the cursor crosses the tree boundary
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group, buffer = bufnr,
    callback = function(ev) update_modifiable(ev.buf) end,
  })

  -- Re-anchor region when content above the tree is edited (tree line numbers shift)
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group, buffer = bufnr,
    callback = function(ev)
      local state = get_state(ev.buf)
      if not state.visible then return end       -- fired during our own render; ignore
      local header = find_header_line(ev.buf)
      if not header then return end              -- fired during our own remove; ignore
      local new_region = region_from_header(ev.buf, header)
      local delta      = new_region.start_line - state.region.start_line
      if delta ~= 0 then
        local new_smap = {}
        for k, v in pairs(state.source_map) do new_smap[k + delta] = v end
        state.source_map = new_smap
      end
      state.region = new_region
      update_modifiable(ev.buf)
    end,
  })

  -- Friendly message instead of the silent E21 Neovim would give
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group, buffer = bufnr,
    callback = function(ev)
      if not M.in_region(ev.buf, vim.api.nvim_win_get_cursor(0)[1]) then return end
      vim.cmd("stopinsert")
      vim.notify("[logseq.nvim] Namespace tree is read-only.", vim.log.levels.INFO)
    end,
  })

  -- Strip tree before write so it is never saved to disk; restore it after
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group, buffer = bufnr,
    callback = function(ev)
      local state = get_state(ev.buf)
      if not state.visible then return end
      state._had_tree = true
      M.remove_section(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group, buffer = bufnr,
    callback = function(ev)
      local state = get_state(ev.buf)
      if not state._had_tree then return end
      state._had_tree = false
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then M.render_section(ev.buf) end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group, buffer = bufnr,
    callback = function(ev)
      vim.bo[ev.buf].modifiable = true
      M._state[ev.buf] = nil
    end,
  })
end

return M
