--- logseq.nvim UI
--- Winbar, statusline, save indicator, syntax concealment, and highlights.

local M = {}

M._state = {
  saved_buffers = {},
  tabline_active = false,
  orig_showtabline = nil,
  orig_tabline = nil,
}

local WINBAR_LEFT = "%@v:lua.logseq_sl_prev_day@◀%X  %@v:lua.logseq_sl_today@📅%X  %@v:lua.logseq_sl_next_day@▶%X"

local BLOCK_NS = vim.api.nvim_create_namespace("logseq_block_ui")

-- ── Helpers ───────────────────────────────────────────────────────────

--- Safely escapes magic characters for Lua's string.gsub pattern matching
local function escape_lua_pattern(str)
  return str:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
end

-- ── Global Shims for Winbar/Statusline Click Targets ──────────────────
-- (statusline %@ function names must be simple Lua global references)

_G.logseq_rename_page  = function(...) M.rename_page(...) end
_G.logseq_close_win    = function(...) M.close_win(...) end

-- Winbar buttons (file/nav)
_G.logseq_sl_search    = function() require("logseq.file_search").open() end
_G.logseq_sl_backlinks = function() require("logseq.backlinks").toggle() end
_G.logseq_sl_queries   = function() require("logseq.queries").toggle() end
_G.logseq_sl_calsync   = function() require("logseq.calendar").sync() end
_G.logseq_sl_nstree    = function() require("logseq.namespace_tree").toggle() end

-- Journal day navigation
local function _open_journal_day(offset)
  local config = require("logseq.config").current
  local vault  = config.vault_path or ""
  local fmt    = config.journal_format or "%Y_%m_%d"
  local dir    = vim.fs.joinpath(vault, "journals")

  -- Try to parse current buffer's date; fall back to today
  local filepath = vim.api.nvim_buf_get_name(0)
  local stem     = vim.fn.fnamemodify(filepath, ":t"):gsub("%.md$", "")
  local y, mo, d = stem:match("^(%d%d%d%d)[_%-](%d%d)[_%-](%d%d)")
  local base_ts
  if y then
    base_ts = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
  else
    base_ts = os.time()
  end

  local target_ts   = base_ts + offset * 86400
  local target_name = os.date(fmt, target_ts) .. ".md"
  local target_path = vim.fs.joinpath(dir, target_name)

  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
  if vim.bo.modified then vim.cmd("write") end
  vim.cmd("edit " .. vim.fn.fnameescape(target_path))
end

_G.logseq_sl_prev_day = function() _open_journal_day(-1) end
_G.logseq_sl_today    = function() vim.cmd("LogseqToday") end
_G.logseq_sl_next_day = function() _open_journal_day(1) end

-- Statusline buttons (editing/cursor)
_G.logseq_sl_follow    = function() require("logseq.links").follow() end
_G.logseq_sl_fold      = function() vim.cmd("normal! za") end
_G.logseq_sl_todo      = function() require("logseq.editing").cycle_todo() end
_G.logseq_sl_indent    = function() vim.cmd("normal! >>") end
_G.logseq_sl_unindent  = function() vim.cmd("normal! <<") end
_G.logseq_sl_moveup    = function() require("logseq.motions").move_up() end
_G.logseq_sl_movedown  = function() require("logseq.motions").move_down() end

-- ── UI Components ─────────────────────────────────────────────────────

function M.winbar()
  local winid = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local name = vim.fn.fnamemodify(filepath, ":t")

  if name == "" then return "" end

  local wb = (require("logseq.config").current.winbar_buttons) or {}

  local nav_parts = {}
  if wb.search    ~= false then table.insert(nav_parts, "%@v:lua.logseq_sl_search@^k🔍%X") end
  if wb.backlinks ~= false then table.insert(nav_parts, "%@v:lua.logseq_sl_backlinks@b🖇️%X") end
  if wb.queries   ~= false then table.insert(nav_parts, "%@v:lua.logseq_sl_queries@q❔%X") end
  if wb.calsync   ~= false then table.insert(nav_parts, "%@v:lua.logseq_sl_calsync@c🗓️%X") end
  if wb.ns_tree   ~= false then table.insert(nav_parts, "%@v:lua.logseq_sl_nstree@n🌳%X") end

  local nav_btns  = "%=%#Comment#" .. table.concat(nav_parts, " ") .. "%#Normal#"
  local close_btn = wb.close ~= false and "  %#Comment#%@v:lua.logseq_close_win@:wq❌%X%#Normal#" or ""

  if M._state.saved_buffers[bufnr] then
    return " " .. WINBAR_LEFT .. "  ✓ Saved" .. nav_btns .. close_btn
  end

  local ok, reminders = pcall(require, "logseq.reminders")
  if ok then
    local event_text = reminders.next_meeting_str()
    if event_text ~= "" then
      return " " .. WINBAR_LEFT .. "%<  │  " .. event_text .. nav_btns .. close_btn
    end
  end

  return " " .. WINBAR_LEFT .. nav_btns .. close_btn
end

-- ── Page/Journal Tabline (above winbar) ──────────────────────────────

--- Build the tabline string shown above the winbar.
function M.tabline()
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.b[bufnr].logseq_active then return "" end

  local config = require("logseq.config")
  if (config.current.winbar_buttons or {}).page_tabline == false then return "" end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return "" end

  local util         = require("logseq.util")
  local vault        = config.current.vault_path or ""
  local norm_path    = util.normalize(filepath)
  local journals_dir = util.normalize(vault .. "/journals")
  local filename     = vim.fn.fnamemodify(filepath, ":t"):gsub("%.md$", "")

  local label
  if norm_path:find(journals_dir, 1, true) then
    label = util.format_journal_date(filename, vault) or util.decode_filename(filename)
  else
    label = util.decode_filename(filename)
  end

  local safe_label = label:gsub("%%", "%%%%")
  local rename_btn = "%#Comment#%@v:lua.logseq_rename_page@rn📝%X%#TabLine#"
  return "%#TabLineSel# " .. safe_label
       .. " %#TabLine#%=" .. rename_btn .. " "
end

--- Activate the custom tabline (called when entering a logseq buffer).
function M.enable_tabline()
  if M._state.tabline_active then return end
  M._state.tabline_active  = true
  M._state.orig_showtabline = vim.o.showtabline
  M._state.orig_tabline     = vim.o.tabline
  vim.opt.showtabline = 2
  vim.opt.tabline     = "%{%v:lua.require('logseq.ui').tabline()%}"
end

--- Restore the original tabline (called when leaving all logseq buffers).
function M.disable_tabline()
  if not M._state.tabline_active then return end
  M._state.tabline_active = false
  vim.opt.showtabline = M._state.orig_showtabline or 1
  vim.opt.tabline     = M._state.orig_tabline     or ""
end

function M.trigger_save_indicator(bufnr)
  M._state.saved_buffers[bufnr] = true
  vim.cmd("redrawstatus")

  vim.defer_fn(function()
    M._state.saved_buffers[bufnr] = nil
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.cmd("redrawstatus")
    end
  end, 1500)
end

function M.close_win(_minwid, _clicks, _button, _mods)
  vim.cmd("wq")
end

-- ── Page Renaming ─────────────────────────────────────────────────────

--- Rewrite [[old_name]] → [[new_name]] in a single file.
--- Returns true if the file was changed.
local function rewrite_file_links(file, old_pat, new_link)
  local rf, err_r = io.open(file, "r")
  if not rf then
    vim.notify("Could not read " .. file .. ": " .. (err_r or "unknown"), vim.log.levels.WARN)
    return false
  end
  local content = rf:read("*a")
  rf:close()

  local new_content = content:gsub(old_pat, new_link)
  if new_content == content then return false end

  local wf, err_w = io.open(file, "w")
  if not wf then
    vim.notify("Could not write " .. file .. ": " .. (err_w or "unknown"), vim.log.levels.WARN)
    return false
  end
  wf:write(new_content)
  wf:close()
  return true
end

--- Replace all [[old_name]] → [[new_name]] in every .md file under vault.
--- Returns the count of files changed.
local function rewrite_links(vault, old_name, new_name)
  local old_pat  = "%[%[" .. escape_lua_pattern(old_name) .. "%]%]"
  local new_link = "[[" .. new_name .. "]]"
  local updated  = 0

  for _, dir in ipairs({ vault .. "/pages", vault .. "/journals" }) do
    if vim.fn.isdirectory(dir) == 1 then
      for _, file in ipairs(vim.fn.glob(dir .. "/*.md", false, true)) do
        if rewrite_file_links(file, old_pat, new_link) then
          updated = updated + 1
        end
      end
    end
  end
  return updated
end

function M.rename_page(_minwid, _clicks, _button, _mods)
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  local config = require("logseq.config")
  local util = require("logseq.util")
  local vault = config.current.vault_path
  local pages_dir = util.normalize(vault .. "/pages")

  if not util.normalize(filepath):find(pages_dir, 1, true) then
    vim.notify("Only pages can be renamed (not journals)", vim.log.levels.WARN)
    return
  end

  local old_name = util.decode_filename(vim.fn.fnamemodify(filepath, ":t"))

  vim.ui.input({ prompt = "Rename page: ", default = old_name }, function(new_name)
    if not new_name or new_name == "" or new_name == old_name then return end

    local new_filepath = pages_dir .. "/" .. util.encode_filename(new_name)

    if vim.bo[bufnr].modified then
      vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
    end

    -- Rename the file first; only rewrite links if that succeeds.
    local ok, err = os.rename(filepath, new_filepath)
    if not ok then
      vim.notify("Rename failed: " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end

    local updated = rewrite_links(vault, old_name, new_name)
    vim.cmd("edit " .. vim.fn.fnameescape(new_filepath))
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.notify(string.format("Renamed to '%s'. %d file(s) updated.", new_name, updated), vim.log.levels.INFO)
  end)
end

-- ── Floating Help Window ──────────────────────────────────────────────

function M.open_help()
  local km = require("logseq.config").current.keymaps or {}
  local function k(name, default) return km[name] or default or "?" end

  local lines = {
    "  Logseq.nvim Help",
    " ──────────────────────────────────────────────────────",
    "",
    "  COMMANDS",
    "   :LogseqToday          Open (or create) today's journal",
    "   :LogseqNewPage [name] Create or open a page",
    "   :LogseqConfig         Open shortcuts & UI config window",
    "   :LogseqCalSync        Manually sync calendar to journal",
    "   :LogseqCalAdd         Add an ICS calendar feed URL",
    "   :LogseqCalEdit        View / add / remove calendar URLs",
    "   :LogseqCalRemind      Set reminder lead time in minutes",
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
    "  NOTE: The page/journal name bar above the winbar can be toggled",
    "        via :LogseqConfig → winbar buttons → 📄/📅",
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

  local max_w = 0
  for _, l in ipairs(lines) do
    if #l > max_w then max_w = #l end
  end
  local width = math.min(max_w + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "logseq_help"

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Logseq.nvim Help ",
    title_pos = "center",
  })

  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  local close = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })
end

-- ── Block Display ─────────────────────────────────────────────────────

--- Refresh virtual empty lines above every root-level block (indent = 0).
local function update_block_virt_lines(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, BLOCK_NS, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local lnum = i - 1
    if lnum > 0 and line:match("^%- ") then
      vim.api.nvim_buf_set_extmark(bufnr, BLOCK_NS, lnum, 0, {
        virt_lines       = { { { "", "Normal" } } },
        virt_lines_above = true,
      })
    end
  end
end

local function setup_syntax(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    -- Hide id:: property lines entirely
    pcall(vim.cmd, [[syntax match LogseqUID /^\s*id::.*$/ conceal]])

    -- Calendar time slots
    pcall(vim.fn.matchadd, "LogseqTime", [[\d\{2}:\d\{2}-\d\{2}:\d\{2}]])
    pcall(vim.fn.matchadd, "LogseqTime", [[(Heldags)]])

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

    -- Block-level formatting: root=bold, level2=italic, level3+=normal
    -- contains=ALL lets nested items (links, tags) still apply their own highlight
    pcall(vim.cmd, [[syntax match LogseqLevel2Block /^\t- .*$/ contains=ALL]])
    pcall(vim.cmd, [[syntax match LogseqRootBlock /^- .*$/ contains=ALL]])
  end)
end

local _hl_autocmd_set = false

local function setup_highlights()
  vim.api.nvim_set_hl(0, "LogseqTime",         { fg = "#e06c60", ctermfg = 167 })
  vim.api.nvim_set_hl(0, "LogseqLink",         { fg = "#7daea3", underline = true, ctermfg = 109, cterm = { underline = true } })
  vim.api.nvim_set_hl(0, "LogseqBlockRef",     { fg = "#a9b665", underline = true, italic = true, ctermfg = 142, cterm = { underline = true, italic = true } })
  vim.api.nvim_set_hl(0, "LogseqTag",          { fg = "#d3869b", underline = true, ctermfg = 175, cterm = { underline = true } })
  vim.api.nvim_set_hl(0, "LogseqStrike",       { strikethrough = true, fg = "#928374", ctermfg = 245, cterm = { strikethrough = true } })
  vim.api.nvim_set_hl(0, "LogseqStrikeDelim",  { link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqLinkDelim",    { link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqBlockRefDelim",{ link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqRootBlock",    { bold = true })
  vim.api.nvim_set_hl(0, "LogseqLevel2Block",  { italic = true })
  vim.api.nvim_set_hl(0, "LogseqStatusLine",   { fg = "#a89984", bg = "#3c3836", ctermfg = 246, ctermbg = 237 })

  if not _hl_autocmd_set then
    _hl_autocmd_set = true
    vim.api.nvim_create_autocmd("ColorScheme", {
      group    = vim.api.nvim_create_augroup("LogseqHighlights", { clear = true }),
      callback = setup_highlights,
    })
  end
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
  vim.opt_local.winbar = "%{%v:lua.require('logseq.ui').winbar()%}"
  vim.opt_local.statusline = M.build_statusline()
  vim.opt_local.winhl = "StatusLine:LogseqStatusLine"
  M.enable_tabline()

  local km = require("logseq.config").current.keymaps
  vim.keymap.set("n", km.help or "hh", M.open_help, { buffer = bufnr, desc = "Logseq Help" })
  if km.search_pages then
    vim.keymap.set("n", km.search_pages, function()
      require("logseq.file_search").open()
    end, { buffer = bufnr, desc = "Logseq Search Pages" })
  end

  -- Save indicator
  local grp = vim.api.nvim_create_augroup("LogseqUI_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = grp,
    buffer = bufnr,
    callback = function(ev) M.trigger_save_indicator(ev.buf) end,
  })

  vim.opt_local.conceallevel = 2
  setup_syntax(bufnr)
  setup_highlights()
  update_block_virt_lines(bufnr)

  -- Refresh virtual spacing after edits
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = grp,
    buffer = bufnr,
    callback = function() update_block_virt_lines(bufnr) end,
  })

  -- Active-event highlight + tabline on buffer enter
  vim.api.nvim_create_autocmd("BufEnter", {
    group = grp,
    buffer = bufnr,
    callback = function()
      M.enable_tabline()
      pcall(function() require("logseq.reminders").update_highlight() end)
    end,
  })

  -- Restore tabline when leaving this buffer if no other logseq buffer is visible
  vim.api.nvim_create_autocmd("BufLeave", {
    group = grp,
    buffer = bufnr,
    callback = function()
      vim.schedule(function()
        local new_buf = vim.api.nvim_get_current_buf()
        if not vim.b[new_buf].logseq_active then
          M.disable_tabline()
        end
      end)
    end,
  })
end

return M

