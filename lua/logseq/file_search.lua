--- logseq.nvim file search
--- Floating fuzzy picker for vault pages (Ctrl+K).
--- Scope toggles between Pages only and All vault files (pages + journals).

local M = {}

local config = require("logseq.config")
local util   = require("logseq.util")

-- ── Scoring (reused from page_search logic) ───────────────────────────

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
      local pi = 1
      local matched, cs, last = false, 0, -1
      for i = 1, #str do
        if str:sub(i,i) == word:sub(pi,pi) then
          cs   = cs + (last == i - 1 and 10 or 1)
          last = i
          pi   = pi + 1
          if pi > #word then matched = true; break end
        end
      end
      if not matched then return -1 end
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
      table.insert(items, {
        name  = util.decode_filename(basename),
        path  = file,
        label = label,
      })
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
    -- No query: return all, alphabetically
    local out = vim.deepcopy(entries)
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
  end

  local scored = {}
  for _, e in ipairs(entries) do
    local s = score(e.name, query)
    if s >= 0 then
      table.insert(scored, { entry = e, score = s })
    end
  end
  table.sort(scored, function(a, b)
    if a.score == b.score then return a.entry.name < b.entry.name end
    return a.score > b.score
  end)

  local out = {}
  for _, v in ipairs(scored) do table.insert(out, v.entry) end
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

local W = 70   -- window width

local function scope_header()
  local parts = {}
  for i, s in ipairs(SCOPES) do
    if i == state.scope_idx then
      table.insert(parts, "[" .. s .. "]")
    else
      table.insert(parts, " " .. s .. " ")
    end
  end
  return "🔍 " .. table.concat(parts, " · ") .. "   Search: " .. state.query .. "_"
end

local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end

  local lines = {}

  -- Header row
  table.insert(lines, " " .. scope_header())
  table.insert(lines, string.rep("─", W))

  -- Results
  local max_rows = vim.api.nvim_win_get_height(state.win) - 4
  local show_label = SCOPES[state.scope_idx] == "All"

  for i, e in ipairs(state.results) do
    if i > max_rows then break end
    local prefix = (i == state.cursor) and " > " or "   "
    local suffix = show_label and ("  [" .. e.label .. "]") or ""
    local name   = e.name
    -- truncate if too long
    local max_name = W - #prefix - #suffix - 2
    if vim.fn.strdisplaywidth(name) > max_name then
      name = name:sub(1, max_name - 1) .. "…"
    end
    table.insert(lines, prefix .. name .. suffix)
  end

  if #state.results == 0 then
    table.insert(lines, "   (no matches)")
  end

  -- Footer
  table.insert(lines, string.rep("─", W))
  table.insert(lines, "  [Tab] scope  [j/k] navigate  [Enter] open  [Esc] cancel")

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  -- Highlight selected result line (offset: header=1, divider=1, so result i is at line i+1)
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  local sel_line = state.cursor + 1  -- 0-indexed: header(0), divider(1), result[1] = line 2
  vim.api.nvim_buf_add_highlight(state.buf, ns, "Visual", sel_line, 0, -1)
end

local function refresh()
  local scope   = SCOPES[state.scope_idx]
  local entries = get_entries(scope)
  state.results = filter_entries(entries, state.query)
  state.cursor  = math.min(state.cursor, math.max(1, #state.results))
  render()
end

-- ── Actions ───────────────────────────────────────────────────────────

local function open_selected()
  local e = state.results[state.cursor]
  if not e then return end
  -- Close picker first
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
  vim.cmd("edit " .. vim.fn.fnameescape(e.path))
end

local function close_picker()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
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
  if char == "\127" or char == "\8" then  -- backspace
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

    -- Special keys
    if char == "\27" then          -- Esc
      close_picker(); return
    elseif char == "\r" then       -- Enter
      open_selected(); return
    elseif char == "\t" then       -- Tab
      toggle_scope()
    elseif char == "j" or char == "\14" then  -- j or Ctrl-N
      move_cursor(1)
    elseif char == "k" or char == "\16" then  -- k or Ctrl-P
      move_cursor(-1)
    elseif char:byte(1) == 0x1b then          -- arrow keys (ESC [ A/B)
      local seq = char:sub(2)
      if seq == "[A" then move_cursor(-1)
      elseif seq == "[B" then move_cursor(1)
      end
    else
      handle_char(char)
    end

    start_key_loop()
  end, 0)
end

-- ── Public open ───────────────────────────────────────────────────────

function M.open(opts)
  opts = opts or {}

  -- Reset state
  state.scope_idx = opts.scope == "all" and 2 or 1
  state.query     = ""
  state.cursor    = 1

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = "logseq-search"

  -- Window dimensions
  local ui_dims = vim.api.nvim_list_uis()[1] or { height = 40, width = 100 }
  local height  = math.min(20, ui_dims.height - 6)
  local row     = math.floor((ui_dims.height - height) / 2)
  local col     = math.floor((ui_dims.width  - W)      / 2)

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

  -- Initial render
  refresh()

  -- Start interactive key loop
  start_key_loop()
end

return M
