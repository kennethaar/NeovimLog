--- logseq.nvim favorites picker
--- ff  → open this floating picker
--- <leader>f → toggle current page as favorite

local M = {}

local config = require("logseq.config")
local util   = require("logseq.util")

local KEY_UP   = vim.api.nvim_replace_termcodes("<Up>",   true, true, true)
local KEY_DOWN = vim.api.nvim_replace_termcodes("<Down>", true, true, true)

local state = { buf = nil, win = nil, cursor = 1, results = {} }
local ns    = vim.api.nvim_create_namespace("logseq_favorites")

-- ── Data ──────────────────────────────────────────────────────────────

local function get_entries()
  local vault = config.current.vault_path
  local results = {}
  for _, name in ipairs(config.get_favorites()) do
    local page_path    = vault .. "/pages/"   .. util.encode_filename(name)
    local journal_path = vault .. "/journals/" .. name .. ".md"
    local path
    if     vim.fn.filereadable(page_path)    == 1 then path = page_path
    elseif vim.fn.filereadable(journal_path) == 1 then path = journal_path
    end
    results[#results + 1] = { name = name, path = path, missing = path == nil }
  end
  return results
end

-- ── Rendering ─────────────────────────────────────────────────────────

local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  local W     = vim.api.nvim_win_get_width(state.win)
  local lines = {}

  lines[#lines + 1] = " ⭐ Favorites"
  lines[#lines + 1] = string.rep("─", W)

  if #state.results == 0 then
    lines[#lines + 1] = "   (no favorites yet)"
    lines[#lines + 1] = "   Press <leader>f on any page to add it"
  else
    for i, e in ipairs(state.results) do
      local prefix = (i == state.cursor) and " > " or "   "
      local tag    = e.missing and " [missing]" or ""
      local max_w  = W - #prefix - #tag - 1
      local name   = e.name
      if vim.fn.strdisplaywidth(name) > max_w then
        name = name:sub(1, math.max(1, max_w - 1)) .. "…"
      end
      lines[#lines + 1] = prefix .. name .. tag
    end
  end

  lines[#lines + 1] = string.rep("─", W)
  if W < 50 then
    lines[#lines + 1] = " [↵] open  [d] remove  [Esc]"
  else
    lines[#lines + 1] = "  [j/k/↑↓] nav  [Enter] open  [d] remove  [Esc] close"
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  if state.cursor >= 1 and state.cursor <= #state.results then
    vim.api.nvim_buf_add_highlight(state.buf, ns, "Visual", state.cursor + 1, 0, -1)
  end
end

-- ── Actions ───────────────────────────────────────────────────────────

local function close_picker()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
end

local function open_selected()
  local e = state.results[state.cursor]
  if not e or e.missing then return end
  close_picker()
  vim.cmd("edit " .. vim.fn.fnameescape(e.path))
end

local function remove_selected()
  local e = state.results[state.cursor]
  if not e then return end
  config.toggle_favorite(e.name)
  state.results = get_entries()
  state.cursor  = math.min(state.cursor, math.max(1, #state.results))
  render()
end

local function move_cursor(delta)
  state.cursor = math.max(1, math.min(#state.results, state.cursor + delta))
  render()
end

-- ── Key loop ──────────────────────────────────────────────────────────

local function start_key_loop()
  vim.defer_fn(function()
    if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
    local ok, char = pcall(vim.fn.getcharstr)
    if not ok or not char then close_picker(); return end

    if     char == "\27"                   then close_picker()
    elseif char == "\r"                    then open_selected()
    elseif char == "d"                     then remove_selected();  start_key_loop()
    elseif char == "j" or char == KEY_DOWN then move_cursor(1);     start_key_loop()
    elseif char == "k" or char == KEY_UP   then move_cursor(-1);    start_key_loop()
    else                                        start_key_loop()
    end
  end, 0)
end

-- ── Public API ────────────────────────────────────────────────────────

function M.open()
  state.cursor  = 1
  state.results = get_entries()

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false

  local ui  = vim.api.nvim_list_uis()[1] or { height = 40, width = 80 }
  local W   = math.max(40, math.min(60, ui.width - 4))
  local H   = math.min(math.max(#state.results + 5, 8), ui.height - 6)
  local row = math.floor((ui.height - H) / 2)
  local col = math.max(0, math.floor((ui.width - W) / 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = W,
    height    = H,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " ⭐ Favorites ",
    title_pos = "center",
  })
  state.win = win
  vim.wo[win].wrap           = false
  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn     = "no"

  render()
  start_key_loop()
end

--- Toggle favorite for the current buffer's page and notify.
function M.toggle_current()
  local filepath = vim.api.nvim_buf_get_name(0)
  if filepath == "" then return end
  local name  = util.decode_filename(vim.fn.fnamemodify(filepath, ":t"))
  local added = config.toggle_favorite(name)
  local msg   = added and ("⭐ Added to favorites: " .. name)
                       or ("Removed from favorites: " .. name)
  vim.notify("[logseq] " .. msg, vim.log.levels.INFO)
end

return M
