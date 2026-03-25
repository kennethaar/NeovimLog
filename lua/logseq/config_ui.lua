--- logseq.nvim config UI
--- Floating window to view/edit keymaps and winbar/bottombar button visibility.

local M = {}

local config = require("logseq.config")

-- ── Definitions ───────────────────────────────────────────────────────

local KEYMAP_DEFS = {
  { key = "next_sibling",     desc = "Move to next sibling" },
  { key = "prev_sibling",     desc = "Move to prev sibling" },
  { key = "first_child",      desc = "Jump to first child" },
  { key = "parent",           desc = "Jump to parent" },
  { key = "move_down",        desc = "Swap block down" },
  { key = "move_up",          desc = "Swap block up" },
  { key = "promote",          desc = "Outdent block" },
  { key = "demote",           desc = "Indent block" },
  { key = "new_sibling",      desc = "New sibling block" },
  { key = "fold_toggle",      desc = "Toggle fold" },
  { key = "follow_link",      desc = "Follow link" },
  { key = "toggle_backlinks", desc = "Toggle backlinks" },
  { key = "todo_cycle",       desc = "Cycle TODO state" },
  { key = "help",             desc = "Show help" },
  { key = "search_pages",     desc = "Search pages / all files" },
  { key = "rename_page",      desc = "Rename page" },
}

local WINBAR_DEFS = {
  { key = "page_tabline", label = "📄/📅",   desc = "Page/journal name bar (above winbar)" },
  { key = "rename",       label = "rn📝",    desc = "Rename page" },
  { key = "search",       label = "^k🔍",   desc = "Search pages / all files" },
  { key = "backlinks",    label = "b🖇️",    desc = "Toggle backlinks" },
  { key = "queries",      label = "q❔",     desc = "Toggle queries" },
  { key = "calsync",      label = "c🗓️",    desc = "Calendar sync" },
  { key = "close",        label = ":wq❌",   desc = "Close window" },
}

local BOTTOMBAR_DEFS = {
  { key = "follow_link", label = "🔗↩️",  desc = "Follow link" },
  { key = "fold_toggle", label = "⚡za",   desc = "Toggle fold" },
  { key = "todo_cycle",  label = "✅^t",   desc = "Cycle TODO state" },
  { key = "indent",      label = ">>",     desc = "Indent" },
  { key = "unindent",    label = "<<",     desc = "Outdent" },
  { key = "move_up",     label = "alt⬆️",  desc = "Move block up" },
  { key = "move_down",   label = "alt⬇️",  desc = "Move block down" },
}

-- ── State ─────────────────────────────────────────────────────────────

local state = {
  buf          = nil,
  win          = nil,
  keymaps      = {},
  winbar       = {},
  bottombar    = {},
  line_map     = {},   -- line_map[lnum] = { type, key }
  action_lines = {},   -- ordered list of actionable lnums
  cursor_idx   = 1,    -- index into action_lines
}

-- ── Helpers ───────────────────────────────────────────────────────────

local W = 68  -- buffer width

local function pad(s, n)
  local len = vim.fn.strdisplaywidth(s)
  if len >= n then return s end
  return s .. string.rep(" ", n - len)
end

local function divider(char)
  return "  " .. string.rep(char or "─", W - 4)
end

-- ── Build buffer content ──────────────────────────────────────────────

local function build()
  local lines       = {}
  local line_map    = {}
  local action_lines = {}

  local function add(line, meta)
    table.insert(lines, line)
    if meta then
      local lnum = #lines
      line_map[lnum] = meta
      table.insert(action_lines, lnum)
    end
  end

  local function plain(line) table.insert(lines, line) end

  -- Header
  plain(string.rep("═", W))
  local title = "Logseq Shortcuts Config"
  plain(string.rep(" ", math.floor((W - #title) / 2)) .. title)
  plain(string.rep("═", W))
  plain("")

  -- ── KEYMAPS ───────────────────────────────────────────────────────
  plain("  KEYMAPS                                         [Enter] edit")
  plain(divider())
  plain("  " .. pad("Action", 22) .. pad("Key", 16) .. "Description")
  plain(divider())
  for _, def in ipairs(KEYMAP_DEFS) do
    local val  = state.keymaps[def.key] or ""
    local line = "  " .. pad(def.key, 22) .. pad(val, 16) .. def.desc
    add(line, { type = "keymap", key = def.key })
  end
  plain("")

  -- ── WINBAR BUTTONS ────────────────────────────────────────────────
  plain("  WINBAR BUTTONS                               [Space] toggle")
  plain(divider())
  plain("  " .. pad("", 7) .. pad("Button", 14) .. "Description")
  plain(divider())
  for _, def in ipairs(WINBAR_DEFS) do
    local vis  = state.winbar[def.key]
    local chk  = vis and "[x]" or "[ ]"
    local line = "  " .. chk .. "  " .. pad(def.label, 14) .. def.desc
    add(line, { type = "winbar", key = def.key })
  end
  plain("")

  -- ── BOTTOMBAR BUTTONS ─────────────────────────────────────────────
  plain("  BOTTOMBAR BUTTONS                            [Space] toggle")
  plain(divider())
  plain("  " .. pad("", 7) .. pad("Button", 14) .. "Description")
  plain(divider())
  for _, def in ipairs(BOTTOMBAR_DEFS) do
    local vis  = state.bottombar[def.key]
    local chk  = vis and "[x]" or "[ ]"
    local line = "  " .. chk .. "  " .. pad(def.label, 14) .. def.desc
    add(line, { type = "bottombar", key = def.key })
  end
  plain("")

  -- Footer
  plain(string.rep("═", W))
  plain("  [w] Save   [r] Reset defaults   [q] Quit")
  plain(string.rep("═", W))

  return lines, line_map, action_lines
end

-- ── Render ────────────────────────────────────────────────────────────

local ns = vim.api.nvim_create_namespace("logseq_config_ui")

local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end

  local lines, line_map, action_lines = build()
  state.line_map     = line_map
  state.action_lines = action_lines

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)

  -- Dim all actionable lines slightly
  for lnum in pairs(line_map) do
    vim.api.nvim_buf_add_highlight(state.buf, ns, "CursorLine", lnum - 1, 0, -1)
  end

  -- Highlight the selected row
  local cur_lnum = action_lines[state.cursor_idx]
  if cur_lnum then
    vim.api.nvim_buf_add_highlight(state.buf, ns, "Visual", cur_lnum - 1, 0, -1)
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_set_cursor(state.win, { cur_lnum, 2 })
    end
  end
end

-- ── Navigation & actions ──────────────────────────────────────────────

local function move_cursor(delta)
  local n = #state.action_lines
  if n == 0 then return end
  state.cursor_idx = math.max(1, math.min(n, state.cursor_idx + delta))
  render()
end

local function current_meta()
  local lnum = state.action_lines[state.cursor_idx]
  return lnum and state.line_map[lnum]
end

local function do_edit()
  local meta = current_meta()
  if not meta or meta.type ~= "keymap" then return end

  local current = state.keymaps[meta.key] or ""
  vim.ui.input(
    { prompt = "New key for [" .. meta.key .. "]: ", default = current },
    function(input)
      if input == nil then return end  -- cancelled
      state.keymaps[meta.key] = (input == "") and (config.defaults.keymaps[meta.key] or "") or input
      render()
    end
  )
end

local function do_toggle()
  local meta = current_meta()
  if not meta then return end

  if meta.type == "winbar" then
    state.winbar[meta.key] = not state.winbar[meta.key]
  elseif meta.type == "bottombar" then
    state.bottombar[meta.key] = not state.bottombar[meta.key]
  end
  render()
end

local function do_save()
  config.save_keymaps_and_ui(state.keymaps, state.winbar, state.bottombar)

  -- Refresh statusline in all active logseq buffers immediately
  local ui = require("logseq.ui")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[bufnr] and vim.b[bufnr].logseq_active then
      pcall(function()
        vim.api.nvim_buf_call(bufnr, function()
          vim.opt_local.statusline = ui.build_statusline()
        end)
      end)
    end
  end
  vim.cmd("redraw!")

  vim.notify(
    "[logseq.nvim] Saved. Reopen buffers for keymap changes to take effect.",
    vim.log.levels.INFO
  )
end

local function do_reset()
  state.keymaps = vim.deepcopy(config.defaults.keymaps)
  for _, def in ipairs(WINBAR_DEFS) do state.winbar[def.key] = true end
  for _, def in ipairs(BOTTOMBAR_DEFS) do state.bottombar[def.key] = true end
  render()
end

local function do_quit()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
end

local function jump_to_next_section()
  local meta = current_meta()
  local cur_type = meta and meta.type or "keymap"
  local order = { keymap = "winbar", winbar = "bottombar", bottombar = "keymap" }
  local next_type = order[cur_type]
  for i, lnum in ipairs(state.action_lines) do
    local m = state.line_map[lnum]
    if m and m.type == next_type then
      state.cursor_idx = i
      render()
      return
    end
  end
end

-- ── Open ──────────────────────────────────────────────────────────────

function M.open()
  -- Load working copies from current config
  state.keymaps   = vim.deepcopy(vim.tbl_deep_extend(
    "force", config.defaults.keymaps, config.current.keymaps or {}))

  local wb = config.current.winbar_buttons or {}
  for _, def in ipairs(WINBAR_DEFS) do
    state.winbar[def.key] = wb[def.key] ~= false
  end

  local bb = config.current.bottombar_buttons or {}
  for _, def in ipairs(BOTTOMBAR_DEFS) do
    state.bottombar[def.key] = bb[def.key] ~= false
  end

  state.cursor_idx = 1

  -- Create scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].filetype  = "logseq-config"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false

  -- Centered floating window
  local ui_dims = vim.api.nvim_list_uis()[1]
  local height  = math.min(44, ui_dims.height - 4)
  local row     = math.floor((ui_dims.height - height) / 2)
  local col     = math.floor((ui_dims.width  - W) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = W,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " Logseq Config ",
    title_pos = "center",
  })
  state.win = win

  vim.wo[win].cursorline      = false
  vim.wo[win].number          = false
  vim.wo[win].relativenumber  = false
  vim.wo[win].signcolumn      = "no"
  vim.wo[win].wrap            = false

  render()

  -- Keymaps
  local o = { buffer = buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "j",       function() move_cursor(1)  end, o)
  vim.keymap.set("n", "k",       function() move_cursor(-1) end, o)
  vim.keymap.set("n", "<Down>",  function() move_cursor(1)  end, o)
  vim.keymap.set("n", "<Up>",    function() move_cursor(-1) end, o)
  vim.keymap.set("n", "<CR>",    do_edit,    o)
  vim.keymap.set("n", "<Space>", do_toggle,  o)
  vim.keymap.set("n", "w",       do_save,    o)
  vim.keymap.set("n", "r",       do_reset,   o)
  vim.keymap.set("n", "q",       do_quit,    o)
  vim.keymap.set("n", "<Esc>",   do_quit,    o)
  vim.keymap.set("n", "<Tab>",   jump_to_next_section, o)
end

return M
