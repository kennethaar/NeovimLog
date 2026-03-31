--- logseq.nvim UI
--- Winbar, statusline, save indicator, syntax concealment, and highlights.

local parser = require("logseq.parser")
local util   = require("logseq.util")

local M = {}

M._state = {
  saved_buffers = {},
  tabline_active = false,
  orig_showtabline = nil,
  orig_tabline = nil,
}

local WINBAR_LEFT = "%@v:lua.logseq_sl_prev_day@◀%X  %@v:lua.logseq_sl_today@📅%X  %@v:lua.logseq_sl_next_day@▶%X"

local BLOCK_NS = vim.api.nvim_create_namespace("logseq_block_ui")
local SCHED_NS  = vim.api.nvim_create_namespace("logseq_scheduled")

-- Per-buffer pending flag: ensures at most one deferred virt-line update is
-- queued per buffer at any time, coalescing bursts of TextChanged events
-- (e.g. during the write lifecycle when sections are removed).
local _vl_pending = {}

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
_G.logseq_sl_calsync   = function() require("logseq.calendar").sync() end

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
_G.logseq_sl_backlinks = function() require("logseq.panels").toggle_key("backlinks") end
_G.logseq_sl_queries   = function() require("logseq.panels").toggle_key("queries")   end
_G.logseq_sl_nstree    = function() require("logseq.panels").toggle_key("ns_tree")   end
_G.logseq_sl_fold      = function() vim.cmd("normal! za") end
_G.logseq_sl_todo      = function() require("logseq.editing").cycle_todo() end
_G.logseq_sl_indent    = function() vim.cmd("normal! >>") end
_G.logseq_sl_unindent  = function() vim.cmd("normal! <<") end
_G.logseq_sl_moveup    = function() require("logseq.motions").move_up() end
_G.logseq_sl_movedown  = function() require("logseq.motions").move_down() end

-- Forward declaration: get_breadcrumb is defined later in this file but
-- referenced by M.winbar(). Declaring the upvalue here keeps M.winbar()
-- from falling through to the (nil) global of the same name.
local get_breadcrumb

-- ── UI Components ─────────────────────────────────────────────────────

function M.winbar()
  local winid = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local name = vim.fn.fnamemodify(filepath, ":t")

  if name == "" then return "" end

  local config = require("logseq.config")
  local wb = (config.current.winbar_buttons) or {}

  local util        = require("logseq.util")
  local vault       = config.current.vault_path or ""
  local norm_path   = util.normalize(filepath)
  local is_journal  = norm_path:find(util.normalize(vault .. "/journals"), 1, true) ~= nil

  local nav_parts = {}
  if wb.search    ~= false then table.insert(nav_parts, "%@v:lua.logseq_sl_search@^k🔍%X") end
  if wb.backlinks ~= false then table.insert(nav_parts, "%@v:lua.logseq_sl_backlinks@b🖇️%X") end
  if wb.queries   ~= false then table.insert(nav_parts, "%@v:lua.logseq_sl_queries@q❔%X") end
  if wb.calsync   ~= false and is_journal  then table.insert(nav_parts, "%@v:lua.logseq_sl_calsync@c🗓️%X") end
  if wb.ns_tree   ~= false and not is_journal then table.insert(nav_parts, "%@v:lua.logseq_sl_nstree@n🌳%X") end

  local nav_btns  = "    %#Comment#" .. table.concat(nav_parts, "  ") .. "%#Normal#"
  local close_btn = ""

  if M._state.saved_buffers[bufnr] then
    return " " .. WINBAR_LEFT .. nav_btns .. "%<   ✓ Saved"
  end

  local ok, reminders = pcall(require, "logseq.reminders")
  if ok then
    local event_text = reminders.next_meeting_str()
    if event_text ~= "" then
      return " " .. WINBAR_LEFT .. nav_btns .. "%<  │  " .. event_text
    end
  end

  local crumb = get_breadcrumb(winid, bufnr)
  if crumb ~= "" then
    local safe = crumb:gsub("%%", "%%%%")
    return " " .. WINBAR_LEFT .. nav_btns .. "  %#LogseqBreadcrumb#" .. safe .. "%#Normal#" .. close_btn
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
  local rename_btn = "%#Comment#%@v:lua.logseq_rename_page@📝rn%X%#TabLine#"
  local close_btn  = "%#Comment#%@v:lua.logseq_close_win@:wq❌%X%#TabLine#"
  -- %< is the truncation point: content before it is never cut, content
  -- after it shrinks first. Buttons are before %<; label truncates instead.
  return " " .. rename_btn .. "  %#TabLineSel#%<" .. safe_label
       .. "%#TabLine#%=" .. close_btn .. " "
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
  local bufnr = vim.api.nvim_get_current_buf()
  -- Pre-strip all panels so no vim.schedule restore can re-dirty the buffer
  -- between the write and quit phases of :wq (which would cause E37).
  pcall(function() require("logseq.panels").close_all(bufnr) end)
  vim.cmd("wq")
end

-- ── Page Renaming ─────────────────────────────────────────────────────

--- Extract the leaf segment of a (possibly namespaced) page name.
--- "Math/Calculus" → "Calculus",  "Foo Bar" → "Foo Bar"
local function leaf_name(name)
  return name:match("[^/]+$") or name
end

--- Build a set of lowercase words from a string.
local function word_set(str)
  local s = {}
  for w in str:lower():gmatch("%S+") do s[w] = true end
  return s
end

--- Jaccard similarity between two word sets (0.0–1.0).
local function jaccard(a, b)
  local inter, union = 0, 0
  for w in pairs(a) do
    union = union + 1
    if b[w] then inter = inter + 1 end
  end
  for w in pairs(b) do
    if not a[w] then union = union + 1 end
  end
  return union == 0 and 1.0 or (inter / union)
end

--- Scan pages_dir for a page whose leaf name is ≥80% word-Jaccard similar
--- to new_name's leaf. Requires ≥2 words to avoid single-word false positives.
--- Excludes new_name itself and the current page (old_name) from candidates.
--- Returns (decoded_name, filepath) of the first match, or nil.
local function find_similar_page(pages_dir, new_name, old_name, util)
  local target_leaf  = leaf_name(new_name)
  local target_words = word_set(target_leaf)
  local n = 0
  for _ in pairs(target_words) do n = n + 1 end
  if n < 2 then return nil end

  for _, file in ipairs(vim.fn.glob(pages_dir .. "/*.md", false, true)) do
    local decoded = util.decode_filename(vim.fn.fnamemodify(file, ":t"))
    if decoded ~= new_name and decoded ~= old_name then
      if jaccard(target_words, word_set(leaf_name(decoded))) >= 0.8 then
        return decoded, file
      end
    end
  end
end

--- Read a file's full content from disk. Returns the string, or nil on error.
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  return c
end

--- Rewrite [[old]] → [[new]] for each {old,new} pair across all .md files in
--- vault. Files are processed in batches so the UI stays responsive throughout.
--- on_done(total_updated) is called when the scan is complete.
local function rewrite_links_async(vault, rewrites, on_done)
  local files = {}
  for _, dir in ipairs({ vault .. "/pages", vault .. "/journals" }) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.list_extend(files, vim.fn.glob(dir .. "/*.md", false, true))
    end
  end

  local patterns = {}
  for _, r in ipairs(rewrites) do
    patterns[#patterns + 1] = {
      pat  = "%[%[" .. escape_lua_pattern(r[1]) .. "%]%]",
      link = "[[" .. r[2] .. "]]",
    }
  end

  local updated, i = 0, 0
  local BATCH = 10

  local function step()
    for _ = 1, BATCH do
      i = i + 1
      if i > #files then on_done(updated); return end
      local content = read_file(files[i])
      if content then
        local new_content = content
        for _, p in ipairs(patterns) do
          new_content = new_content:gsub(p.pat, p.link)
        end
        if new_content ~= content then
          local wf = io.open(files[i], "w")
          if wf then wf:write(new_content); wf:close(); updated = updated + 1 end
        end
      end
    end
    vim.schedule(step)
  end
  vim.schedule(step)
end

--- Switch to dest_path immediately so the user sees it at once, then in the next
--- tick: append extra_path content below a --- divider (when merging), write the
--- buffer, delete any listed paths, and rewrite vault references asynchronously.
--- rewrites  = list of { old_name, new_name } pairs
--- notify_fn = function(n_updated) called when the ref scan is complete
local function finish(bufnr, dest_path, extra_path, to_delete, vault, rewrites, notify_fn)
  vim.cmd("silent edit " .. vim.fn.fnameescape(dest_path))
  vim.api.nvim_buf_delete(bufnr, { force = true })

  vim.schedule(function()
    if extra_path then
      local src = read_file(extra_path)
      if src then
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
        vim.list_extend(lines, { "", "---", "" })
        vim.list_extend(lines, vim.split(src:gsub("%s+$", ""), "\n", { plain = true }))
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.cmd("silent write")
      end
    end

    for _, path in ipairs(to_delete) do os.remove(path) end
    rewrite_links_async(vault, rewrites, notify_fn)
  end)
end

--- Core rename/merge logic. Runs inside a vim.schedule after vim.ui.input closes.
local function do_rename(bufnr, filepath, old_name, new_name, vault, pages_dir, util)
  local new_filepath = pages_dir .. "/" .. util.encode_filename(new_name)

  if vim.bo[bufnr].modified then
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
  end

  -- Case 1: target already exists → offer to merge current below it
  if vim.fn.filereadable(new_filepath) == 1 then
    vim.ui.select(
      { "Merge '" .. old_name .. "' below '" .. new_name .. "'", "Cancel" },
      { prompt = "'" .. new_name .. "' already exists:" },
      function(_, idx)
        if idx ~= 1 then return end
        finish(bufnr, new_filepath, filepath, { filepath }, vault,
          { { old_name, new_name } },
          function(n)
            vim.notify(("Merged into '%s'. %d file(s) updated."):format(new_name, n), vim.log.levels.INFO)
          end)
      end)
    return
  end

  -- Case 2: similar page found → choose which name to keep
  local sim_name, sim_path = find_similar_page(pages_dir, new_name, old_name, util)
  if sim_name then
    vim.ui.select(
      {
        "Keep '" .. new_name .. "' (merge '" .. sim_name .. "' below)",
        "Keep '" .. sim_name .. "' (merge '" .. old_name .. "' below)",
        "Cancel",
      },
      { prompt = "Similar page '" .. sim_name .. "' found:" },
      function(_, idx)
        if not idx or idx == 3 then return end
        if idx == 1 then
          -- new_name wins: rename source to new_name, then append sim below
          local ok, err = os.rename(filepath, new_filepath)
          if not ok then
            vim.notify("Rename failed: " .. (err or "unknown"), vim.log.levels.ERROR)
            return
          end
          finish(bufnr, new_filepath, sim_path, { sim_path }, vault,
            { { old_name, new_name }, { sim_name, new_name } },
            function(n)
              vim.notify(("Renamed to '%s', merged '%s'. %d file(s) updated.")
                :format(new_name, sim_name, n), vim.log.levels.INFO)
            end)
        else
          -- sim_name wins: open sim, append current source below it
          finish(bufnr, sim_path, filepath, { filepath }, vault,
            { { old_name, sim_name } },
            function(n)
              vim.notify(("Merged into '%s'. %d file(s) updated."):format(sim_name, n), vim.log.levels.INFO)
            end)
        end
      end)
    return
  end

  -- Case 3: no conflict → plain rename
  local ok, err = os.rename(filepath, new_filepath)
  if not ok then
    vim.notify("Rename failed: " .. (err or "unknown"), vim.log.levels.ERROR)
    return
  end
  finish(bufnr, new_filepath, nil, {}, vault,
    { { old_name, new_name } },
    function(n)
      vim.notify(("Renamed to '%s'. %d file(s) updated."):format(new_name, n), vim.log.levels.INFO)
    end)
end

function M.rename_page(_minwid, _clicks, _button, _mods)
  local bufnr    = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  local config    = require("logseq.config")
  local util      = require("logseq.util")
  local vault     = config.current.vault_path
  local pages_dir = util.normalize(vault .. "/pages")

  if not util.normalize(filepath):find(pages_dir, 1, true) then
    vim.notify("Only pages can be renamed (not journals)", vim.log.levels.WARN)
    return
  end

  local old_name = util.decode_filename(vim.fn.fnamemodify(filepath, ":t"))
  vim.ui.input({ prompt = "Rename page: ", default = old_name }, function(new_name)
    if not new_name or new_name == "" or new_name == old_name then return end
    vim.schedule(function()
      do_rename(bufnr, filepath, old_name, new_name, vault, pages_dir, util)
    end)
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
    "   " .. k("rename_page","<leader>rn") .. "   Rename page (+ merge if target exists)",
    "   " .. k("toggle_backlinks","<leader>b") .. "   Toggle backlinks / linked-references panel",
    "   <leader>q             Toggle queries panel",
    "   <leader>t             Apply template to current page",
    "   " .. k("search_pages","<C-k>") .. "   Search pages / all files",
    "",
    "  SLASH COMMANDS  (type / after a space in insert mode)",
    "   /today  /yesterday  /tomorrow  /now",
    "   /TODO  /DOING  /DONE  /WAITING  /CANCELLED",
    "   /scheduled  /deadline",
    "   /embed-page  /embed-block  /page-ref  /block-ref",
    "   /bold  /italic  /code  /highlight  /strike  /hr",
    "   /template",
    "",
    "  FOLDING & TODO",
    "   " .. k("fold_toggle","za") .. "   Toggle fold at cursor",
    "   " .. k("todo_cycle","<C-t>") .. "   Cycle TODO state (normal & insert)",
    "   TODO states:  (none) → TODO → WAITING → DOING → DONE → CANCELLED → (none)",
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

--- Schedule a deferred virt-line update.  If one is already pending for this
--- buffer, the new request is dropped — the existing scheduled call will run
--- after the current event burst (write lifecycle, rapid typing, etc.) settles.
local function schedule_virt_update(bufnr)
  if _vl_pending[bufnr] then return end
  _vl_pending[bufnr] = true
  vim.schedule(function()
    _vl_pending[bufnr] = nil
    update_block_virt_lines(bufnr)
  end)
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
    pcall(vim.cmd, "syntax match LogseqLinkNS /\\%(\\[\\[\\)\\@<=\\zs[^\\]]*\\// contained conceal")

    -- Conceal ((block-refs))
    pcall(vim.cmd, [[syntax region LogseqBlockRef matchgroup=LogseqBlockRefDelim start=/((\ze[^(]/ end=/))/ concealends oneline]])

    -- Conceal #tags
    pcall(vim.cmd, [[syntax match LogseqTagHash /#\ze[[:alnum:]_\-\/]/ conceal]])
    pcall(vim.cmd, [[syntax match LogseqTag /#[[:alnum:]_\-\/]\+/ contains=LogseqTagHash]])

    -- Inline formatting (order matters: __ before _ so double-underscore wins)
    pcall(vim.cmd, [[syntax region LogseqBold      matchgroup=LogseqBoldDelim      start=/\*\*\ze\S/ end=/\S\zs\*\*/ concealends oneline]])
    pcall(vim.cmd, [[syntax region LogseqUnderline matchgroup=LogseqUnderlineDelim start=/__\ze\S/   end=/\S\zs__/   concealends oneline]])
    pcall(vim.cmd, [[syntax region LogseqItalic    matchgroup=LogseqItalicDelim    start=/_\ze\S/    end=/\S\zs_/    concealends oneline]])
    pcall(vim.cmd, [[syntax region LogseqCode      matchgroup=LogseqCodeDelim      start=/`/         end=/`/         concealends oneline]])
    pcall(vim.cmd, [[syntax region LogseqHighlight matchgroup=LogseqHighlightDelim start=/\^\^\ze\S/ end=/\S\zs\^\^/ concealends oneline]])

    -- Strikethrough for ~~cancelled~~ text
    pcall(vim.cmd, [[syntax region LogseqStrike matchgroup=LogseqStrikeDelim start=/\~\~/ end=/\~\~/ concealends oneline]])

    -- Block-level formatting: root=bold, level2=italic, level3+=normal
    -- contains=ALL lets nested items (links, tags) still apply their own highlight
    pcall(vim.cmd, [[syntax match LogseqLevel2Block /^\t- .*$/ contains=ALLBUT,LogseqLinkNS]])
    pcall(vim.cmd, [[syntax match LogseqRootBlock /^- .*$/ contains=ALLBUT,LogseqLinkNS]])
  end)
end

local _hl_autocmd_set = false

local function setup_highlights()
  vim.api.nvim_set_hl(0, "LogseqTime",         { fg = "#e06c60", ctermfg = 167 })
  vim.api.nvim_set_hl(0, "LogseqLink",         { fg = "#7daea3", underline = true, ctermfg = 109, cterm = { underline = true } })
  vim.api.nvim_set_hl(0, "LogseqBlockRef",     { fg = "#a9b665", underline = true, italic = true, ctermfg = 142, cterm = { underline = true, italic = true } })
  vim.api.nvim_set_hl(0, "LogseqTag",          { fg = "#d3869b", underline = true, ctermfg = 175, cterm = { underline = true } })
  vim.api.nvim_set_hl(0, "LogseqBold",           { bold = true })
  vim.api.nvim_set_hl(0, "LogseqBoldDelim",      { link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqItalic",         { italic = true })
  vim.api.nvim_set_hl(0, "LogseqItalicDelim",    { link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqUnderline",      { underline = true })
  vim.api.nvim_set_hl(0, "LogseqUnderlineDelim", { link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqCode",           { fg = "#d8a657", bg = "#32302f", ctermfg = 214, ctermbg = 236 })
  vim.api.nvim_set_hl(0, "LogseqCodeDelim",      { link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqHighlight",      { bg = "#b57614", fg = "#1d2021", ctermbg = 136, ctermfg = 234 })
  vim.api.nvim_set_hl(0, "LogseqHighlightDelim", { link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqStrike",         { strikethrough = true, fg = "#928374", ctermfg = 245, cterm = { strikethrough = true } })
  vim.api.nvim_set_hl(0, "LogseqStrikeDelim",    { link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqLinkDelim",    { link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqBlockRefDelim",{ link = "Conceal" })
  vim.api.nvim_set_hl(0, "LogseqRootBlock",    { bold = true })
  vim.api.nvim_set_hl(0, "LogseqLevel2Block",  { italic = true })
  vim.api.nvim_set_hl(0, "LogseqStatusLine",   { fg = "#a89984", bg = "#3c3836", ctermfg = 246, ctermbg = 237 })
  vim.api.nvim_set_hl(0, "LogseqScheduled",    { fg = "#d8a657", ctermfg = 214 })
  vim.api.nvim_set_hl(0, "LogseqDeadline",     { fg = "#ea6962", ctermfg = 203 })
  vim.api.nvim_set_hl(0, "LogseqBreadcrumb",   { fg = "#7c6f64", ctermfg = 243 })
  vim.api.nvim_set_hl(0, "LogseqEmbedHeader",  { fg = "#504945", ctermfg = 239 })
  vim.api.nvim_set_hl(0, "LogseqEmbedText",    { fg = "#928374", ctermfg = 245 })

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

-- ── Scheduled / Deadline virtual text ────────────────────────────────

--- Render SCHEDULED:: / DEADLINE:: dates as eol virtual text on the bullet line.
--- Uses util.prop_ci for case-insensitive property lookup and util.match_ci
--- instead of [Ss][Cc][Hh]… character classes.
local function update_scheduled_virt(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, SCHED_NS, 0, -1)

  local ok, result = pcall(parser.parse_buf, bufnr)
  if not ok then return end

  for _, block in ipairs(parser.flatten(result.blocks)) do
    if block.is_scheduled then
      local sched    = util.prop_ci(block.properties, "scheduled")
      local deadline = util.prop_ci(block.properties, "deadline")

      -- Fall back to scanning the bullet content for inline SCHEDULED:: / DEADLINE::
      if not sched    then sched    = util.match_ci(block.content, "scheduled::%s*(<[^>]+>)") end
      if not deadline then deadline = util.match_ci(block.content, "deadline::%s*(<[^>]+>)") end

      local parts = {}
      if sched then
        local d = sched:match("<(%d%d%d%d%-%d%d%-%d%d)")
        if d then parts[#parts + 1] = { "  📅 " .. d, "LogseqScheduled" } end
      end
      if deadline then
        local d = deadline:match("<(%d%d%d%d%-%d%d%-%d%d)")
        if d then parts[#parts + 1] = { "  ⏰ " .. d, "LogseqDeadline" } end
      end

      if #parts > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, SCHED_NS, block.line_start - 1, 0, {
          virt_text     = parts,
          virt_text_pos = "eol",
        })
      end
    end
  end
end

-- ── Breadcrumb helper ─────────────────────────────────────────────────

--- Return an abbreviated ancestor chain for the block at the cursor in `winid`.
--- Accepts the window id so it queries the correct cursor position even when
--- the winbar is evaluated for a non-focused window.
--- Format: "Grandparent › Parent › Current"
---@param winid integer
---@param bufnr integer
---@return string
get_breadcrumb = function(winid, bufnr)
  local ok, result = pcall(parser.parse_buf, bufnr)
  if not ok then return "" end

  local block = parser.block_at_line(result.blocks, vim.api.nvim_win_get_cursor(winid)[1])
  if not block or not block.parent then return "" end

  -- Collect in root→leaf order (O(n) appends) then reverse in place.
  local crumbs = {}
  local b = block
  while b do
    local text = vim.trim(b.content:gsub("%[%[(.-)%]%]", "%1"):gsub("#", ""))
    if #text > 22 then text = text:sub(1, 20) .. "…" end
    crumbs[#crumbs + 1] = text ~= "" and text or "…"
    b = b.parent
  end

  -- In-place reverse so result reads root › … › leaf.
  local n = #crumbs
  for i = 1, math.floor(n / 2) do
    crumbs[i], crumbs[n - i + 1] = crumbs[n - i + 1], crumbs[i]
  end

  if n <= 1 then return "" end
  return table.concat(crumbs, " › ")
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
  if km.rename_page then
    vim.keymap.set("n", km.rename_page, M.rename_page, { buffer = bufnr, desc = "Logseq Rename Page" })
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

  update_scheduled_virt(bufnr)

  -- Refresh virtual spacing and scheduled virt text after edits
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = grp,
    buffer = bufnr,
    callback = function()
      update_block_virt_lines(bufnr)
      update_scheduled_virt(bufnr)
    end,
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

