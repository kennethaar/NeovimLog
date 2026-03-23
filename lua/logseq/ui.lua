--- logseq.nvim UI
--- Winbar, statusline, save indicator, syntax concealment, and highlights.

local M = {}

M._saved_buffers = {}

-- ── Winbar ────────────────────────────────────────────────────────────

-- Global shims so %@v:lua.X@ works without complex require() expressions
-- (statusline %@ function names must be simple Lua global references)
_G.logseq_rename_page  = function(...) M.rename_page(...) end
_G.logseq_close_win    = function(...) M.close_win(...) end
-- winbar buttons (file/nav)
_G.logseq_sl_search    = function() require("logseq.file_search").open() end
_G.logseq_sl_backlinks = function() require("logseq.backlinks").toggle() end
_G.logseq_sl_queries   = function() require("logseq.queries").toggle() end
_G.logseq_sl_calsync   = function() require("logseq.calendar").sync() end
-- statusline buttons (editing/cursor)
_G.logseq_sl_follow    = function() require("logseq.links").follow() end
_G.logseq_sl_fold      = function() vim.cmd("normal! za") end
_G.logseq_sl_todo      = function() require("logseq.editing").cycle_todo() end
_G.logseq_sl_indent    = function() vim.cmd("normal! >>") end
_G.logseq_sl_unindent  = function() vim.cmd("normal! <<") end
_G.logseq_sl_moveup    = function() require("logseq.motions").move_up() end
_G.logseq_sl_movedown  = function() require("logseq.motions").move_down() end

function M.winbar()
  local winid = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local name = vim.fn.fnamemodify(filepath, ":t")
  if name == "" then return "" end

  local title = name:gsub("%.md$", ""):gsub("---", "/")
  -- Escape any literal % in the title so statusline doesn't mis-interpret them
  local safe_title = title:gsub("%%", "%%%%")

  local wb = (require("logseq.config").current.winbar_buttons) or {}

  -- Title + optional rename hint
  local title_btn
  if wb.rename ~= false then
    title_btn = "%@v:lua.logseq_rename_page@" .. safe_title
                .. " %#Comment#rn📝%#Normal#%X"
  else
    title_btn = safe_title
  end

  -- Right-side nav buttons
  local nav_parts = {}
  if wb.search ~= false then
    table.insert(nav_parts, "%@v:lua.logseq_sl_search@^k🔍%X")
  end
  if wb.backlinks ~= false then
    table.insert(nav_parts, "%@v:lua.logseq_sl_backlinks@b🖇️%X")
  end
  if wb.queries ~= false then
    table.insert(nav_parts, "%@v:lua.logseq_sl_queries@q❔%X")
  end
  if wb.calsync ~= false then
    table.insert(nav_parts, "%@v:lua.logseq_sl_calsync@c🗓️%X")
  end
  local nav_btns = "%=%#Comment#" .. table.concat(nav_parts, " ") .. "%#Normal#"

  local close_btn = wb.close ~= false
    and "  %#Comment#%@v:lua.logseq_close_win@:wq❌%X%#Normal#"
    or ""

  if M._saved_buffers[bufnr] then
    return " " .. title_btn .. "  ✓ Saved" .. nav_btns .. close_btn
  end

  local ok, reminders = pcall(require, "logseq.reminders")
  if ok then
    local event_text = reminders.next_meeting_str()
    if event_text ~= "" then
      return " " .. title_btn .. "%<  │  " .. event_text .. nav_btns .. close_btn
    end
  end

  return " " .. title_btn .. nav_btns .. close_btn
end

function M.trigger_save_indicator(bufnr)
  M._saved_buffers[bufnr] = true
  vim.cmd("redraw!")

  vim.defer_fn(function()
    M._saved_buffers[bufnr] = nil
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.cmd("redraw!")
      end
    end)
  end, 1500)
end

function M.close_win(_minwid, _clicks, _button, _mods)
  vim.cmd("wq")
end

--- Rename the current page and update all [[OldName]] links in the vault.
--- Triggered by clicking the title in the winbar.
--- Replace all [[old_name]] → [[new_name]] in every .md file under vault.
--- Returns the count of files changed.
local function rewrite_links(vault, old_name, new_name)
  local old_pat  = "%[%[" .. vim.pesc(old_name) .. "%]%]"
  local new_link = "[[" .. new_name .. "]]"
  local updated  = 0

  for _, dir in ipairs({ vault .. "/pages", vault .. "/journals" }) do
    if vim.fn.isdirectory(dir) == 0 then goto next_dir end
    for _, file in ipairs(vim.fn.glob(dir .. "/*.md", false, true)) do
      local f = io.open(file, "r")
      if not f then goto next_file end
      local ok, content = pcall(function() return f:read("*a") end)
      f:close()
      if not ok then goto next_file end
      local new_content = content:gsub(old_pat, new_link)
      if new_content ~= content then
        local fw = io.open(file, "w")
        if fw then fw:write(new_content); fw:close(); updated = updated + 1 end
      end
      ::next_file::
    end
    ::next_dir::
  end

  return updated
end

function M.rename_page(_minwid, _clicks, _button, _mods)
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  local config = require("logseq.config")
  local util   = require("logseq.util")
  local vault  = config.current.vault_path
  local pages_dir = util.normalize(vault .. "/pages")

  if not util.normalize(filepath):find(pages_dir, 1, true) then
    vim.notify("Only pages can be renamed (not journals)", vim.log.levels.WARN)
    return
  end

  local old_name = util.decode_filename(vim.fn.fnamemodify(filepath, ":t"))

  vim.ui.input({ prompt = "Rename page: ", default = old_name }, function(new_name)
    if not new_name or new_name == "" or new_name == old_name then return end

    local new_filepath = pages_dir .. "/" .. util.encode_filename(new_name)
    local updated = rewrite_links(vault, old_name, new_name)

    if vim.bo[bufnr].modified then
      vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
    end

    local ok, err = os.rename(filepath, new_filepath)
    if not ok then
      vim.notify("Rename failed: " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end

    vim.cmd("edit " .. vim.fn.fnameescape(new_filepath))
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.notify(string.format("Renamed to '%s'. %d file(s) updated.", new_name, updated), vim.log.levels.INFO)
  end)
end

function M.open_help()
  local km = require("logseq.config").current.keymaps or {}

  local function k(name, default)
    return km[name] or default or "?"
  end

  local lines = {
    "  Logseq.nvim Help",
    " ──────────────────────────────────────────────────────",
    "",
    "  COMMANDS",
    "   :LogseqToday          Open (or create) today's journal",
    "   :LogseqNewPage [name] Create or open a page",
    "   :LogseqConfig         Open shortcuts & UI config window",
    "   :Calsync              Manually sync calendar to journal",
    "   :Caladd               Add an ICS calendar feed URL",
    "   :CalEdit              View / add / remove calendar URLs",
    "   :Calremind            Set reminder lead time in minutes",
    "",
    "  NAVIGATION",
    "   " .. k("next_sibling","<leader>j") .. "   Next sibling block",
    "   " .. k("prev_sibling","<leader>k") .. "   Previous sibling block",
    "   " .. k("first_child","<leader>J") .. "   First child block",
    "   " .. k("parent","<leader>K") .. "   Parent block",
    "",
    "  BLOCK EDITING",
    "   o                     New sibling block below (normal mode)",
    "   O                     New sibling block above (normal mode)",
    "   <CR>  (insert)        Smart Enter: new sibling or split",
    "   <S-CR> (insert)       Property / continuation line",
    "   " .. k("demote",">>") .. "   Demote / indent block (with subtree)",
    "   " .. k("promote","<<") .. "   Promote / outdent block (with subtree)",
    "   <Tab>   (normal)      Indent block (alias for >>)",
    "   <S-Tab> (normal)      Outdent block (alias for <<)",
    "   <Tab>   (insert)      Indent block via parser",
    "   <S-Tab> (insert)      Outdent block via parser",
    "   " .. k("move_down","<A-Down>") .. "   Move block down (swap with next sibling)",
    "   " .. k("move_up","<A-Up>") .. "   Move block up (swap with previous sibling)",
    "",
    "  LINKS & REFERENCES",
    "   " .. k("follow_link","<CR>") .. "   Follow wikilink / block-ref / tag",
    "   <CR>  (visual)        Wrap selection in [[...]] or unwrap",
    "   [[                    Trigger fuzzy page-link completion",
    "   " .. k("toggle_backlinks","<leader>b") .. "   Toggle backlinks / linked-references panel",
    "   <leader>q             Toggle queries panel",
    "   <leader>t             Apply template to current page",
    "   " .. k("search_pages","<C-k>") .. "   Search pages / all files",
    "",
    "  FOLDING & TODO",
    "   " .. k("fold_toggle","za") .. "   Toggle fold at cursor",
    "   " .. k("todo_cycle","<C-t>") .. "   Cycle TODO state (normal & insert)",
    "   TODO states:  (none) → TODO → DOING → DONE → CANCELLED → WAITING → (none)",
    "",
    "  HELP & CONFIG",
    "   " .. k("help","hh") .. "   Show this help window",
    "   :LogseqConfig         Remap any hotkey or toggle UI buttons",
    "",
    "  CONFIG UI KEYS  (inside :LogseqConfig window)",
    "   j / k                 Navigate items",
    "   <CR>                  Edit selected keymap",
    "   <Space>               Toggle winbar / bottombar button",
    "   w                     Save changes",
    "   r                     Reset to defaults",
    "   q / <Esc>             Close without saving",
    "   <Tab>                 Jump to next section",
    "",
    "  Press  q  or  <Esc>  to close this window",
    "",
  }

  -- Width: longest line + 2 padding
  local max_w = 0
  for _, l in ipairs(lines) do
    if #l > max_w then max_w = #l end
  end
  local width  = math.min(max_w + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].filetype   = "logseq_help"

  local row = math.floor((vim.o.lines   - height) / 2)
  local col = math.floor((vim.o.columns - width)  / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row      = row,
    col      = col,
    width    = width,
    height   = height,
    style    = "minimal",
    border   = "rounded",
    title    = " Logseq.nvim Help ",
    title_pos = "center",
  })

  vim.wo[win].wrap      = false
  vim.wo[win].cursorline = true

  local close = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  vim.keymap.set("n", "q",     close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })
end

-- ── Syntax Setup ─────────────────────────────────────────────────────
-- (audit #30) Each syntax rule is individually pcall-wrapped so one
-- failure doesn't prevent the rest from loading.

local function setup_syntax(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    -- Hide id:: property lines entirely
    pcall(vim.cmd, [[syntax match LogseqUID /^\s*id::.*$/ conceal]])

    -- Calendar time slots
    pcall(function()
      vim.fn.matchadd("LogseqTime", [[\d\{2}:\d\{2}-\d\{2}:\d\{2}]])
      vim.fn.matchadd("LogseqTime", [[(Heldags)]])
    end)

    -- Conceal [[wikilinks]]
    pcall(vim.cmd, [[syntax region LogseqLink matchgroup=LogseqLinkDelim start=/\[\[/ end=/\]\]/ concealends contains=LogseqLinkNS oneline]])
    pcall(vim.cmd, "syntax match LogseqLinkNS /.*\\// contained conceal")

    -- Conceal ((block-refs))
    pcall(vim.cmd, [[syntax region LogseqBlockRef matchgroup=LogseqBlockRefDelim start=/((\ze[^(]/ end=/))/ concealends oneline]])

    -- Conceal #tags
    pcall(vim.cmd, [[syntax match LogseqTagHash /#\ze[[:alnum:]_\-\/]/ conceal]])
    pcall(vim.cmd, [[syntax match LogseqTag /#[[:alnum:]_\-\/]\+/ contains=LogseqTagHash]])

    -- Strikethrough for ~~cancelled~~ text
    pcall(vim.cmd, [[syntax region LogseqStrike matchgroup=LogseqStrikeDelim start=/\~\~/ end=/\~\~/ concealends oneline]])
  end)
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "LogseqTime",         { fg = "#e06c60", ctermfg = 167 })
  vim.api.nvim_set_hl(0, "LogseqLink",         { fg = "#7daea3", underline = true, ctermfg = 109, cterm = { underline = true } })
  vim.api.nvim_set_hl(0, "LogseqBlockRef",     { fg = "#a9b665", underline = true, italic = true, ctermfg = 142, cterm = { underline = true } })
  vim.api.nvim_set_hl(0, "LogseqTag",          { fg = "#d3869b", underline = true, ctermfg = 175, cterm = { underline = true } })
  vim.api.nvim_set_hl(0, "LogseqStrike",       { strikethrough = true, fg = "#928374", ctermfg = 245, cterm = { strikethrough = true } })
  vim.api.nvim_set_hl(0, "LogseqStrikeDelim",  { link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqLinkDelim",    { link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqBlockRefDelim",{ link = "Conceal" })
  -- Custom dark statusline group used via winhl (survives colorscheme reloads)
  vim.api.nvim_set_hl(0, "LogseqStatusLine", { fg = "#a89984", bg = "#3c3836", ctermfg = 246, ctermbg = 237 })
end

--- Build the statusline string respecting bottombar_buttons visibility config.
---@return string
function M.build_statusline()
  local bb = (require("logseq.config").current.bottombar_buttons) or {}
  local parts = {}
  if bb.follow_link ~= false then table.insert(parts, "%@v:lua.logseq_sl_follow@🔗↩️%X") end
  if bb.fold_toggle ~= false then table.insert(parts, "%@v:lua.logseq_sl_fold@⚡za%X") end
  if bb.todo_cycle  ~= false then table.insert(parts, "%@v:lua.logseq_sl_todo@✅^t%X") end
  if bb.indent      ~= false then table.insert(parts, "%@v:lua.logseq_sl_indent@>>%X") end
  if bb.unindent    ~= false then table.insert(parts, "%@v:lua.logseq_sl_unindent@<<%X") end
  if bb.move_up     ~= false then table.insert(parts, "%@v:lua.logseq_sl_moveup@alt⬆️%X") end
  if bb.move_down   ~= false then table.insert(parts, "%@v:lua.logseq_sl_movedown@alt⬇️%X") end
  return table.concat(parts, "  ")
end

-- ── Buffer Setup ─────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  -- Winbar (audit #15: v:lua.require pattern is safe in opt_local)
  vim.opt_local.winbar = "%{%v:lua.require('logseq.ui').winbar()%}"

  -- Statusline row 2: editing/cursor actions (file/nav buttons are in winbar row 1)
  vim.opt_local.statusline = M.build_statusline()
  vim.opt_local.winhl = "StatusLine:LogseqStatusLine"

  local km = require("logseq.config").current.keymaps
  vim.keymap.set("n", km.help or "hh", M.open_help, { buffer = bufnr, desc = "Logseq Help" })
  if km.search_pages then
    vim.keymap.set("n", km.search_pages, function()
      require("logseq.file_search").open()
    end, { buffer = bufnr, desc = "Logseq Search Pages" })
  end

  -- Save indicator
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    callback = function(ev) M.trigger_save_indicator(ev.buf) end,
  })

  -- Syntax
  vim.opt_local.conceallevel = 2
  setup_syntax(bufnr)
  setup_highlights()

  -- Active-event highlight on buffer enter
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = bufnr,
    callback = function()
      pcall(function() require("logseq.reminders").update_highlight() end)
    end,
  })
end

return M
