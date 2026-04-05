--- logseq.nvim query builder
--- Floating form UI for constructing Logseq simple queries.
---
--- Usage:
---   require("logseq.query_builder").open({
---     existing_ast = ast_or_nil,   -- pre-fill from existing {{query}} block
---     replace_line = lnum_or_nil,  -- if set, replace this buffer line on Insert
---     on_insert    = function(query_str, replace_lnum) ... end,
---   })
---
--- Form layout:
---   ╭──────────── Query Builder ────────────────╮
---   │                                            │
---   │  Combine with:  [AND]  [OR]               │
---   │                                            │
---   │  Predicates:                               │
---   │    1. [[Project X]]         [edit] [del]  │
---   │    2. todo: TODO DOING       [edit] [del]  │
---   │                                            │
---   │    [+ Add predicate]                       │
---   │                                            │
---   │  Preview:                                  │
---   │  {{query (and [[Project X]] (todo TODO))}} │
---   │                                            │
---   │             [ Cancel ]   [ Insert ]        │
---   │                                            │
---   ╰────────────────────────────────────────────╯
---
--- Keymaps (inside the builder window):
---   <CR>   activate item under cursor
---   q / <Esc>  close without inserting

local qparser = require("logseq.query_parser")

local M = {}

-- ── Form state helpers ─────────────────────────────────────────────────

local function new_state(opts)
  return {
    combine      = "and",
    predicates   = {},
    on_insert    = opts.on_insert,
    replace_line = opts.replace_line,
    win_id       = nil,
    buf_id       = nil,
  }
end

--- Deep-copy an AST node into a mutable predicate table.
local function ast_to_pred(ast)
  if not ast then return nil end
  local t = ast.type

  -- Unwrap single-child (and/or) wrappers
  if (t == "and" or t == "or") and #ast.children == 1 then
    return ast_to_pred(ast.children[1])
  end

  if t == "page_link"    then return { type = "page_link",    page  = ast.page } end
  if t == "todo"         then return { type = "todo",         states = vim.deepcopy(ast.states or {}) } end
  if t == "tags"         then return { type = "tags",         tags   = vim.deepcopy(ast.tags   or {}) } end
  if t == "property"     then return { type = "property",     key = ast.key, value = ast.value } end
  if t == "page_property" then return { type = "page_property", key = ast.key, value = ast.value } end
  if t == "between"      then return { type = "between",      from = ast.from, to = ast.to } end
  return nil
end

--- Populate state.predicates and state.combine from an existing AST.
local function load_from_ast(state, ast)
  if not ast then return end
  if ast.type == "and" or ast.type == "or" then
    state.combine = ast.type
    for _, child in ipairs(ast.children or {}) do
      local p = ast_to_pred(child)
      if p then state.predicates[#state.predicates + 1] = p end
    end
  else
    local p = ast_to_pred(ast)
    if p then state.predicates[#state.predicates + 1] = p end
  end
end

-- ── Query string builder ───────────────────────────────────────────────

local function pred_to_ast(p)
  if p.type == "page_link"     then return { type = "page_link",    page  = p.page } end
  if p.type == "todo"          then return { type = "todo",         states = p.states } end
  if p.type == "tags"          then return { type = "tags",         tags   = p.tags } end
  if p.type == "property"      then return { type = "property",     key = p.key, value = p.value } end
  if p.type == "page_property" then return { type = "page_property", key = p.key, value = p.value } end
  if p.type == "between"       then return { type = "between",      from = p.from, to = p.to } end
  return nil
end

local function build_query_str(state)
  if #state.predicates == 0 then return "" end

  local children = {}
  for _, p in ipairs(state.predicates) do
    local node = pred_to_ast(p)
    if node then children[#children + 1] = node end
  end

  if #children == 1 then return qparser.to_string(children[1]) end

  return qparser.to_string({ type = state.combine, children = children })
end

-- ── Form rendering ─────────────────────────────────────────────────────

local function quote_value(value)
  if not value then return nil end
  return '"' .. value:gsub('([\\"])', '\\%1') .. '"'
end

local function pred_label(p)
  if p.type == "page_link"     then return "[[" .. (p.page or "?") .. "]]" end
  if p.type == "todo"          then return "todo: " .. table.concat(p.states or {}, " ") end
  if p.type == "tags"          then return "tags: " .. table.concat(p.tags  or {}, " ") end
  if p.type == "property"      then
    return "prop: :" .. (p.key or "?") .. (p.value and (" = " .. quote_value(p.value)) or "")
  end
  if p.type == "page_property" then
    return "page-prop: :" .. (p.key or "?") .. (p.value and (" = " .. quote_value(p.value)) or "")
  end
  if p.type == "between"       then
    return "between: " .. (p.from or "?") .. " — " .. (p.to or "?")
  end
  return "unknown"
end

--- Build form lines and a click_map: { [line_idx] = { action, ... } | { buttons = [...] } }
local function render_form(state)
  local lines    = {}
  local click_map = {}

  local function add(line, entry)
    lines[#lines + 1] = line
    if entry then click_map[#lines] = entry end
    return #lines
  end

  add("")

  -- Combine buttons
  local and_btn = state.combine == "and" and "[AND]" or "[and]"
  local or_btn  = state.combine == "or"  and "[OR]"  or "[or]"
  local combine_line = "  Combine with:  " .. and_btn .. "  " .. or_btn

  local function find_range(s, pat)
    local from, to = s:find(pat, 1, true)
    return from, to
  end

  local and_from, and_to = find_range(combine_line, and_btn)
  local or_from,  or_to  = find_range(combine_line, or_btn)
  add(combine_line, {
    buttons = {
      { from = and_from, to = and_to, action = "set_combine", data = "and" },
      { from = or_from,  to = or_to,  action = "set_combine", data = "or"  },
    }
  })

  add("")
  add("  Predicates:")

  for i, p in ipairs(state.predicates) do
    local label   = string.format("    %d. %-38s", i, pred_label(p))
    local edit_s  = #label + 1
    local edit_e  = edit_s + 5
    local del_s   = edit_e + 2
    local del_e   = del_s + 4
    local pline   = label .. "[edit]  [del]"
    add(pline, {
      buttons = {
        { from = edit_s, to = edit_e, action = "edit_pred",   data = i },
        { from = del_s,  to = del_e,  action = "delete_pred", data = i },
      }
    })
  end

  add("")
  add("    [+ Add predicate]", { action = "add_pred" })
  add("")

  -- Preview
  local qs = build_query_str(state)
  add("  Preview:")
  if qs ~= "" then
    add("  {{query " .. qs .. "}}")
  else
    add("  (add at least one predicate)")
  end

  add("")

  -- Action buttons
  local footer    = "             [ Cancel ]   [ Insert ]"
  local cancel_s, cancel_e = find_range(footer, "[ Cancel ]")
  local insert_s, insert_e = find_range(footer, "[ Insert ]")
  add(footer, {
    buttons = {
      { from = cancel_s, to = cancel_e, action = "cancel" },
      { from = insert_s, to = insert_e, action = "insert" },
    }
  })
  add("")

  return lines, click_map
end

--- Write rendered form content into the builder buffer.
local function refresh_form(state)
  if not state.buf_id or not vim.api.nvim_buf_is_valid(state.buf_id) then return end
  local lines, click_map = render_form(state)
  state.click_map = click_map

  vim.bo[state.buf_id].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf_id, 0, -1, false, lines)
  vim.bo[state.buf_id].modifiable = false

  -- Highlights
  local NS_B = vim.api.nvim_create_namespace("logseq_qbuilder")
  vim.api.nvim_buf_clear_namespace(state.buf_id, NS_B, 0, -1)

  for line_idx, entry in pairs(click_map) do
    local row = line_idx - 1
    if entry.buttons then
      for _, btn in ipairs(entry.buttons) do
        local hl = (btn.action == "set_combine" and btn.data == state.combine) and "Bold"
                or (btn.action == "insert")                                     and "DiagnosticOk"
                or (btn.action == "cancel" or btn.action == "delete_pred")      and "DiagnosticError"
                or "Special"
        vim.api.nvim_buf_add_highlight(state.buf_id, NS_B, hl, row, btn.from - 1, btn.to)
      end
    end
  end
end

-- ── Predicate input helpers ────────────────────────────────────────────

local PRED_TYPES = {
  "[[page link]]",
  "todo states",
  "task states",
  "tags",
  "property key/value",
  "page-property key/value",
  "between dates",
}

local function ask_page(callback)
  vim.ui.select(
    { "current page", "other page..." },
    { prompt = "Page link:" },
    function(choice)
      if not choice then return end
      if choice == "current page" then
        callback({ type = "page_link", page = "current page" })
        return
      end
      vim.ui.input({ prompt = "Page name: " }, function(input)
        if not input or input:match("^%s*$") then return end
        callback({ type = "page_link", page = input:match("^%s*(.-)%s*$") })
      end)
    end
  )
end

local function ask_todo(existing, callback)
  local default = existing and table.concat(existing, ",") or "TODO,DOING"
  vim.ui.input({
    prompt  = "TODO states (comma-separated, e.g. TODO,DOING): ",
    default = default,
  }, function(input)
    if not input then return end
    local states = {}
    for s in input:gmatch("[^,]+") do
      local trimmed = s:match("^%s*(.-)%s*$"):upper()
      if trimmed ~= "" then states[#states + 1] = trimmed end
    end
    if #states > 0 then callback({ type = "todo", states = states }) end
  end)
end

local function ask_tags(existing, callback)
  local default = existing and table.concat(existing, " ") or ""
  vim.ui.input({
    prompt  = "Tags (space-separated, without #): ",
    default = default,
  }, function(input)
    if not input then return end
    local tags = {}
    for t in input:gmatch("%S+") do tags[#tags + 1] = t end
    if #tags > 0 then callback({ type = "tags", tags = tags }) end
  end)
end

local function normalize_property_key(key)
  if not key or key:match("^%s*$") then return "" end
  local trimmed = key:match("^%s*(.-)%s*$")
  if trimmed:sub(1, 1) == ":" then trimmed = trimmed:sub(2) end
  return trimmed
end

local function ask_kv(node_type, prompt_key, existing_key, existing_val, callback)
  vim.ui.input({ prompt = prompt_key .. " key: ", default = existing_key or "" }, function(key)
    if not key or key:match("^%s*$") then return end
    key = normalize_property_key(key)
    vim.ui.input({ prompt = prompt_key .. " value (leave blank = any): ", default = existing_val or "" },
      function(val)
        local v = val and val:match("^%s*(.-)%s*$")
        callback({ type = node_type, key = key, value = (v ~= "" and v or nil) })
      end)
  end)
end

local function ask_between(existing_from, existing_to, callback)
  vim.ui.input({ prompt = "From date (YYYY-MM-DD): ", default = existing_from or "" }, function(from)
    if not from or from:match("^%s*$") then return end
    from = from:match("^%s*(.-)%s*$")
    vim.ui.input({ prompt = "To date (YYYY-MM-DD): ", default = existing_to or "" }, function(to)
      if not to or to:match("^%s*$") then return end
      to = to:match("^%s*(.-)%s*$")
      callback({ type = "between", from = from, to = to })
    end)
  end)
end

local function ask_predicate(choice, existing, callback)
  if choice == PRED_TYPES[1] then
    ask_page(callback)
  elseif choice == PRED_TYPES[2] then
    ask_todo(existing and existing.states, callback)
  elseif choice == PRED_TYPES[3] then
    ask_tags(existing and existing.tags, callback)
  elseif choice == PRED_TYPES[4] then
    ask_kv("property", "Property", existing and existing.key, existing and existing.value, callback)
  elseif choice == PRED_TYPES[5] then
    ask_kv("page_property", "Page-property", existing and existing.key, existing and existing.value, callback)
  elseif choice == PRED_TYPES[6] then
    ask_between(existing and existing.from, existing and existing.to, callback)
  end
end

-- ── Action dispatcher ──────────────────────────────────────────────────

local function execute_action(state, action, data)
  if action == "cancel" then
    if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
      vim.api.nvim_win_close(state.win_id, true)
    end

  elseif action == "insert" then
    local qs = build_query_str(state)
    if qs == "" then
      vim.notify("[logseq.nvim] Add at least one predicate.", vim.log.levels.WARN)
      return
    end
    if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
      vim.api.nvim_win_close(state.win_id, true)
    end
    if state.on_insert then state.on_insert(qs, state.replace_line) end

  elseif action == "set_combine" then
    state.combine = data
    refresh_form(state)

  elseif action == "add_pred" then
    vim.ui.select(PRED_TYPES, { prompt = "Add predicate:" }, function(choice)
      if not choice then return end
      ask_predicate(choice, nil, function(pred)
        state.predicates[#state.predicates + 1] = pred
        refresh_form(state)
      end)
    end)

  elseif action == "edit_pred" then
    local idx = data
    local p   = state.predicates[idx]
    if not p then return end

    local type_map = {
      page_link    = PRED_TYPES[1], todo         = PRED_TYPES[2],
      tags         = PRED_TYPES[3], property     = PRED_TYPES[4],
      page_property = PRED_TYPES[5], between     = PRED_TYPES[6],
    }
    local choice = type_map[p.type]
    if not choice then return end

    ask_predicate(choice, p, function(new_pred)
      state.predicates[idx] = new_pred
      refresh_form(state)
    end)

  elseif action == "delete_pred" then
    table.remove(state.predicates, data)
    refresh_form(state)
  end
end

--- Dispatch a <CR> press inside the builder at (cursor_line, cursor_col).
local function on_enter(state)
  local cursor  = vim.api.nvim_win_get_cursor(state.win_id)
  local line_1  = cursor[1]          -- 1-indexed
  local col_1   = cursor[2] + 1      -- 1-indexed byte

  local entry = state.click_map and state.click_map[line_1]
  if not entry then return end

  if entry.action then
    -- Single-action line (e.g. [+ Add predicate])
    execute_action(state, entry.action, entry.data)
    return
  end

  if entry.buttons then
    for _, btn in ipairs(entry.buttons) do
      if col_1 >= btn.from and col_1 <= btn.to then
        execute_action(state, btn.action, btn.data)
        return
      end
    end
    -- Cursor is on the line but not on a button: activate the leftmost button.
    if #entry.buttons > 0 then
      local btn = entry.buttons[1]
      execute_action(state, btn.action, btn.data)
    end
  end
end

-- ── Public API ─────────────────────────────────────────────────────────

--- Open the query builder in a floating window.
---@param opts table  { existing_ast, replace_line, on_insert }
function M.open(opts)
  opts = opts or {}

  local state = new_state(opts)
  if opts.existing_ast then load_from_ast(state, opts.existing_ast) end

  -- Create scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].filetype   = "logseq_query_builder"
  state.buf_id = buf

  -- Size and position
  local ui     = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
  local width  = math.min(58, ui.width - 4)
  local height = math.min(18, ui.height - 4)
  local row    = math.floor((ui.height - height) / 2)
  local col    = math.floor((ui.width  - width)  / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width    = width,
    height   = height,
    row      = row,
    col      = col,
    style    = "minimal",
    border   = "rounded",
    title    = " Query Builder ",
    title_pos = "center",
  })
  state.win_id = win

  vim.wo[win].wrap       = false
  vim.wo[win].cursorline = true

  -- Render initial form
  refresh_form(state)

  -- Keymaps
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
  end

  map("<CR>",  function() on_enter(state) end)
  map("q",     function() execute_action(state, "cancel") end)
  map("<Esc>", function() execute_action(state, "cancel") end)

  -- Position cursor on first interactive line (combine row)
  pcall(vim.api.nvim_win_set_cursor, win, { 2, 18 })
end

return M
