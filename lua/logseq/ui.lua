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
  -- Hint clarifies that clicking renames AND rewrites all [[refs]] in the vault
  local title_btn = "%@v:lua.logseq_rename_page@" .. safe_title
                    .. " %#Comment#📝(rn)%#Normal#%X"
  local nav_btns = "%=%#Comment#"
    .. "%@v:lua.logseq_sl_backlinks@🖇️b%X "
    .. "%@v:lua.logseq_sl_queries@❔q%X "
    .. "%@v:lua.logseq_sl_calsync@🗓️c%X"
    .. "%#Normal#"
  local close_btn = "  %#Comment#%@v:lua.logseq_close_win@(:q)✕%X%#Normal#"

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
  vim.cmd("q")
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
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local help_file = vim.fn.fnamemodify(src, ":p:h:h") .. "/README.md"

  if vim.fn.filereadable(help_file) == 1 then
    vim.cmd("vsplit " .. vim.fn.fnameescape(help_file))
    return
  end

  vim.notify(
    "Logseq Mode Active!\n" ..
    "• Folding: za\n" ..
    "• Move Block: <Alt-Up/Down>\n" ..
    "• Indent: Tab / Shift-Tab\n" ..
    "• Search Link: [[\n" ..
    "• Add link by selecting text and hitting enter\n" ..
    "• Cycle TODO state by hitting Ctrl + T\n" ..
    "• Trigger calsync with :Calsync\n" ..
    string.format("(Could not locate README at %s)", help_file),
    vim.log.levels.INFO
  )
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

-- ── Buffer Setup ─────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  -- Winbar (audit #15: v:lua.require pattern is safe in opt_local)
  vim.opt_local.winbar = "%{%v:lua.require('logseq.ui').winbar()%}"

  -- Statusline row 2: editing/cursor actions (file/nav buttons are in winbar row 1)
  vim.opt_local.statusline = table.concat({
    "%@v:lua.logseq_sl_follow@🔗↩️%X",
    "%@v:lua.logseq_sl_fold@⚡za%X",
    "%@v:lua.logseq_sl_todo@✅^t%X",
    "%@v:lua.logseq_sl_indent@>>%X",
    "%@v:lua.logseq_sl_unindent@<<%X",
    "%@v:lua.logseq_sl_moveup@alt⬆️%X",
    "%@v:lua.logseq_sl_movedown@alt⬇️%X",
  }, "  ")
  vim.opt_local.winhl = "StatusLine:LogseqStatusLine"

  vim.keymap.set("n", "hh", M.open_help, { buffer = bufnr, desc = "Logseq Help" })

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
