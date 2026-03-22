--- logseq.nvim file search
--- Floating fuzzy picker for vault pages (Ctrl+K).
--- Scope toggles between Pages only and All vault files (pages + journals).

local M = {}

local config = require("logseq.config")
local util   = require("logseq.util")

-- ── Key codes (resolved once at load time) ─────────────────────────────
-- nvim_replace_termcodes produces the same representation getcharstr() returns
-- for special keys, which is NOT the raw escape sequence in all terminals.
local KEY_UP   = vim.api.nvim_replace_termcodes("<Up>",   true, true, true)
local KEY_DOWN = vim.api.nvim_replace_termcodes("<Down>", true, true, true)
local KEY_BS   = vim.api.nvim_replace_termcodes("<BS>",   true, true, true)

-- ── Scoring ────────────────────────────────────────────────────────────

local function score(str, pattern)
  if not pattern or pattern == "" then return 0 end
  str     = str:lower()
  pattern = pattern:lower()

  local exact_idx = str:find(pattern, 1, true)
  if exact_idx then return 10000 - exact_idx end

  local total = 0
  for word in pattern:gmatch("%S+") do
    local wi = str:find(word, 1, true)
    if wi then
      total = total + (1000 - wi)
    else
      -- Fuzzy character-by-character match
      local pi = 1
      local cs, last = 0, -1
      for i = 1, #str do
        if str:byte(i) == word:byte(pi) then
          cs   = cs + (last == i - 1 and 10 or 1)
          last = i
          pi   = pi + 1
          if pi > #word then break end
        end
      end
      if pi <= #word then return -1 end  -- not all chars matched
      total = total + cs
    end
  end
  return total
end

-- ── Vault scanner ─────────────────────────────────────────────────────

local SCOPES = { "Pages", "All" }

local function get_entries(scope)
  local vault = config.current.vault_path
  if not vault or vault == "" then return {} end

  local items = {}

  local function scan(dir, label)
    if vim.fn.isdirectory(dir) == 0 then return end
    for _, file in ipairs(vim.fn.glob(dir .. "/*.md", true, true)) do
      local basename = vim.fn.fnamemodify(file, ":t")
      items[#items + 1] = {
        name  = util.decode_filename(basename),
        path  = file,
        label = label,
      }
    end
  end

  scan(vault .. "/pages", "pages")
  if scope == "All" then
    scan(vault .. "/journals", "journal")
  end

  return items
end

local function filter_entries(entries, query)
  if query == "" then
    local out = {}
    for _, e in ipairs(entries) do out[#out + 1] = e end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
  end

  local scored = {}
  for _, e in ipairs(entries) do
    local s = score(e.name, query)
    if s >= 0 then
      scored[#scored + 1] = { entry = e, score = s }
    end
  end
  table.sort(scored, function(a, b)
    if a.score == b.score then return a.entry.name < b.entry.name end
    return a.score > b.score
  end)

  local out = {}
  for _, v in ipairs(scored) do out[#out + 1] = v.entry end
  return out
end

-- ── State ─────────────────────────────────────────────────────────────

local state = {
  buf        = nil,
  win        = nil,
  scope_idx  = 1,   -- 1 = Pages, 2 = All
  query      = "",
  results    = {},
  cursor     = 1,   -- index into results
}

-- ── Rendering ─────────────────────────────────────────────────────────

local ns = vim.api.nvim_create_namespace("logseq_file_search")

local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end

  local W        = vim.api.nvim_win_get_width(state.win)
  local show_all = SCOPES[state.scope_idx] == "All"
  local lines    = {}

  -- Header: scope tabs + query cursor
  local parts = {}
  for i, s in ipairs(SCOPES) do
    parts[#parts + 1] = (i == state.scope_idx) and ("[" .. s .. "]") or (" " .. s .. " ")
  end
  lines[#lines + 1] = " 🔍 " .. table.concat(parts, " · ") .. "  " .. state.query .. "_"
  lines[#lines + 1] = string.rep("─", W)

  -- Results
  local max_rows = vim.api.nvim_win_get_height(state.win) - 4
  for i, e in ipairs(state.results) do
    if i > max_rows then break end
    local prefix = (i == state.cursor) and " > " or "   "
    if e.is_create then
      lines[#lines + 1] = prefix .. '[+] Create "' .. e.name .. '"'
    else
      local suffix   = show_all and ("  [" .. e.label .. "]") or ""
      local max_name = W - #prefix - #suffix - 2
      local name     = e.name
      if vim.fn.strdisplaywidth(name) > max_name then
        name = name:sub(1, math.max(1, max_name - 1)) .. "…"
      end
      lines[#lines + 1] = prefix .. name .. suffix
    end
  end

  if #state.results == 0 then
    lines[#lines + 1] = "   (no matches)"
  end

  -- Footer (short form for narrow screens)
  lines[#lines + 1] = string.rep("─", W)
  if W < 50 then
    lines[#lines + 1] = " [Tab] [↑↓/jk] [↵] [Esc]"
  else
    lines[#lines + 1] = "  [Tab] scope  [j/k/↑↓] nav  [Enter] open  [Esc] close"
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  -- Highlight selected result (header=line0, divider=line1, result[1]=line2)
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  if state.cursor >= 1 and state.cursor <= #state.results then
    vim.api.nvim_buf_add_highlight(state.buf, ns, "Visual", state.cursor + 1, 0, -1)
  end
end

local function refresh()
  local entries = get_entries(SCOPES[state.scope_idx])
  state.results = filter_entries(entries, state.query)
  -- When query is non-empty and nothing matched, offer to create the page
  if state.query ~= "" and #state.results == 0 then
    state.results = { { name = state.query, is_create = true } }
  end
  state.cursor = math.min(state.cursor, math.max(1, #state.results))
  render()
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
  if not e then return end
  close_picker()
  if e.is_create then
    local vault    = config.current.vault_path
    local filename = util.encode_filename(e.name)
    vim.cmd("edit " .. vim.fn.fnameescape(vault .. "/pages/" .. filename))
  else
    vim.cmd("edit " .. vim.fn.fnameescape(e.path))
  end
end

local function move_cursor(delta)
  state.cursor = math.max(1, math.min(#state.results, state.cursor + delta))
  render()
end

local function toggle_scope()
  state.scope_idx = (state.scope_idx % #SCOPES) + 1
  state.cursor    = 1
  refresh()
end

local function handle_char(char)
  -- Backspace: nvim keycode, DEL (127), or raw BS (8)
  if char == KEY_BS or char == "\127" or char == "\8" then
    state.query = state.query:sub(1, -2)
  else
    state.query = state.query .. char
  end
  state.cursor = 1
  refresh()
end

-- ── Key loop ──────────────────────────────────────────────────────────

local function start_key_loop()
  vim.defer_fn(function()
    if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end

    local ok, char = pcall(vim.fn.getcharstr)
    if not ok or not char then close_picker(); return end

    if     char == "\27"    then close_picker()         -- Esc
    elseif char == "\r"     then open_selected()        -- Enter
    elseif char == "\t"     then toggle_scope();        start_key_loop()
    elseif char == "j"      or char == KEY_DOWN
                            or char == "\14" then       -- j / ↓ / Ctrl-N
      move_cursor(1);  start_key_loop()
    elseif char == "k"      or char == KEY_UP
                            or char == "\16" then       -- k / ↑ / Ctrl-P
      move_cursor(-1); start_key_loop()
    else
      handle_char(char);   start_key_loop()
    end
  end, 0)
end

-- ── Public open ───────────────────────────────────────────────────────

function M.open(opts)
  opts = opts or {}

  state.scope_idx = opts.scope == "all" and 2 or 1
  state.query     = ""
  state.cursor    = 1

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = "logseq-search"

  local ui     = vim.api.nvim_list_uis()[1] or { height = 40, width = 80 }
  local W      = math.max(40, math.min(70, ui.width - 4))
  local height = math.min(20, ui.height - 6)
  local row    = math.floor((ui.height - height) / 2)
  local col    = math.max(0, math.floor((ui.width - W) / 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = W,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " ^k🔍 Page Search ",
    title_pos = "center",
  })
  state.win = win

  vim.wo[win].cursorline     = false
  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn     = "no"
  vim.wo[win].wrap           = false

  refresh()
  start_key_loop()
end

return M
