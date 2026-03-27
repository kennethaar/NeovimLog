--- logseq.nvim panel coordinator
--- Renders a persistent ASCII tab bar at the bottom of each relevant buffer.
--- Queries / backlinks / namespace tree are exclusive tabs: only one visible
--- at a time.  Pressing <CR> on a tab label activates it.
---
--- Tab bar layout (inactive / active):
---
---   ┌───────────┐  ╔═══════════╗  ┌─────────────┐
---   │ Backlinks │  ║  Queries  ║  │  Namespace  │
---   └───────────┘  ╚═══════════╝  └─────────────┘
---
--- The tab bar is never written to disk (stripped on BufWritePre, restored after).

local M = {}
M._state = {} -- bufnr → { vis_start, button_cols, tabs, had_tabbar, active_to_restore }

local config = require("logseq.config")
local NS     = vim.api.nvim_create_namespace("logseq_panels")

local MODS = {
  backlinks = "logseq.backlinks",
  queries   = "logseq.queries",
  ns_tree   = "logseq.namespace_tree",
}

-- Internal flag names used by each module's write-lifecycle handler.
-- panels.BufWritePre (which fires last) clears these to suppress the
-- module's own BufWritePost re-render and takes over ordering itself.
local HAD_FLAGS = {
  backlinks = "had_backlinks",
  queries   = "had_queries",
  ns_tree   = "_had_tree",
}

-- ── Helpers ───────────────────────────────────────────────────────────

local function with_modifiable(bufnr, fn)
  local was_mod  = vim.bo[bufnr].modified
  local was_able = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  fn()
  vim.bo[bufnr].modified   = was_mod
  vim.bo[bufnr].modifiable = was_able
end

local function get_state(bufnr)
  if not M._state[bufnr] then
    M._state[bufnr] = {
      vis_start          = nil,
      button_cols        = nil,
      tabs               = nil,
      had_tabbar         = false,
      active_to_restore  = nil,
    }
  end
  return M._state[bufnr]
end

local function is_panel_visible(mod, bufnr)
  local s = mod._state[bufnr]
  return s ~= nil and s.visible == true
end

-- ── Relevance ─────────────────────────────────────────────────────────

local function is_meta_page(filename)
  return filename:match("^Query___") ~= nil or filename:match("^Templates___") ~= nil
end

local function has_query_file(bufnr)
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
  if is_meta_page(filename) then return false end
  local ns = filename:match("^(.-)___")
  if not ns then return false end
  local vault = config.current.vault_path
  if not vault or vault == "" then return false end
  return vim.fn.filereadable(vault .. "/pages/Query___" .. ns .. ".md") == 1
end

local function is_namespace_page(bufnr)
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
  return not is_meta_page(filename) and filename:find("___", 1, true) ~= nil
end

local function get_tabs(bufnr)
  local tabs = { { key = "backlinks", label = "Backlinks" } }
  if has_query_file(bufnr)    then table.insert(tabs, { key = "queries", label = "Queries"   }) end
  if is_namespace_page(bufnr) then table.insert(tabs, { key = "ns_tree", label = "Namespace" }) end
  return tabs
end

-- ── ASCII tab bar builder ─────────────────────────────────────────────

local LABELS_FULL  = { backlinks = "Backlinks", queries = "Queries",  ns_tree = "Namespace" }
local LABELS_SHORT = { backlinks = "Links",     queries = "Query",    ns_tree = "NS"        }

-- Choose full labels if they fit within win_width, otherwise short labels.
local function pick_labels(tabs, win_width)
  local total = 0
  for i, tab in ipairs(tabs) do
    total = total + #(" " .. LABELS_FULL[tab.key] .. " ") + 2  -- label + 2 border chars
    if i < #tabs then total = total + 2 end                     -- gap between buttons
  end
  return total <= win_width and LABELS_FULL or LABELS_SHORT
end

local function build_tabbar_lines(tabs, active, win_width)
  local labels    = pick_labels(tabs, win_width or vim.o.columns)
  local top, mid, bot = "", "", ""
  local button_cols   = {}

  for i, tab in ipairs(tabs) do
    local label   = " " .. labels[tab.key] .. " "
    local width   = #label
    local col_frm = #mid  -- 0-indexed byte offset of the left border char

    if tab.key == active then
      top = top .. "╔" .. string.rep("═", width) .. "╗"
      mid = mid .. "║" .. label .. "║"
      bot = bot .. "╚" .. string.rep("═", width) .. "╝"
    else
      top = top .. "┌" .. string.rep("─", width) .. "┐"
      mid = mid .. "│" .. label .. "│"
      bot = bot .. "└" .. string.rep("─", width) .. "┘"
    end

    -- to = 0-indexed byte offset of the right border char (inclusive)
    table.insert(button_cols, { key = tab.key, from = col_frm, to = #mid - 1 })

    if i < #tabs then
      top = top .. "  "
      mid = mid .. "  "
      bot = bot .. "  "
    end
  end

  return { top, mid, bot }, button_cols
end

-- ── Scan: recover vis_start after line shifts ─────────────────────────

-- The top border always starts with the 3-byte sequence for ┌ or ╔.
-- Scans backwards from EOF, limited to a small window near the expected position.
local TOP_BYTES_SINGLE = string.char(0xE2, 0x94, 0x8C)  -- ┌
local TOP_BYTES_DOUBLE = string.char(0xE2, 0x95, 0x94)  -- ╔

-- hint: current vis_start (1-indexed) used to limit search to last few lines
local function find_tabbar_top(bufnr, hint)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local from  = math.max(0, hint and (hint - 5) or (total - 20))
  local lines = vim.api.nvim_buf_get_lines(bufnr, from, total, false)
  for i = #lines, 1, -1 do
    local b3 = lines[i]:sub(1, 3)
    if b3 == TOP_BYTES_SINGLE or b3 == TOP_BYTES_DOUBLE then
      return from + i  -- convert local index to 1-indexed absolute line
    end
  end
end

-- ── Highlights ────────────────────────────────────────────────────────

local function apply_highlights(bufnr, vis_start, button_cols, active)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  local top0 = vis_start - 1  -- 0-indexed top border line
  for i = 0, 2 do
    vim.api.nvim_buf_add_highlight(bufnr, NS, "Comment", top0 + i, 0, -1)
  end
  if active then
    for _, btn in ipairs(button_cols) do
      if btn.key == active then
        -- Highlight the active button's mid-row label brighter
        vim.api.nvim_buf_add_highlight(bufnr, NS, "Title", top0 + 1, btn.from, btn.to + 1)
      end
    end
  end
end

-- ── Render / update / remove ─────────────────────────────────────────

function M.render_tabbar(bufnr)
  local state = get_state(bufnr)
  local tabs  = get_tabs(bufnr)
  if #tabs == 0 then return end

  local active = nil
  for key, mod_name in pairs(MODS) do
    local ok, mod = pcall(require, mod_name)
    if ok and is_panel_visible(mod, bufnr) then active = key; break end
  end

  local win_width              = vim.api.nvim_win_get_width(0)
  local vis_lines, button_cols = build_tabbar_lines(tabs, active, win_width)
  local line_count             = vim.api.nvim_buf_line_count(bufnr)

  -- Append: empty separator + 3 visual lines
  with_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false,
      vim.list_extend({ "" }, vis_lines))
  end)

  -- vis_start: 1-indexed position of the top border line
  -- (separator is at line_count+1, top border is at line_count+2)
  state.vis_start   = line_count + 2
  state.button_cols = button_cols
  state.tabs        = tabs

  apply_highlights(bufnr, state.vis_start, button_cols, active)
end

--- Re-render only the 3 visual lines in-place (e.g. after a panel toggle).
function M.update_tabbar(bufnr)
  local state = get_state(bufnr)
  if not state.vis_start then return end

  local active = nil
  for key, mod_name in pairs(MODS) do
    local ok, mod = pcall(require, mod_name)
    if ok and is_panel_visible(mod, bufnr) then active = key; break end
  end

  local win_width              = vim.api.nvim_win_get_width(0)
  local vis_lines, button_cols = build_tabbar_lines(state.tabs, active, win_width)
  state.button_cols = button_cols

  local top0 = state.vis_start - 1  -- 0-indexed
  with_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, top0, top0 + 3, false, vis_lines)
  end)

  apply_highlights(bufnr, state.vis_start, button_cols, active)
end

function M.remove_tabbar(bufnr)
  local state = get_state(bufnr)
  if not state.vis_start then return false end

  -- Separator is one line above the top border: 0-indexed = vis_start - 2
  local sep0 = state.vis_start - 2
  with_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, sep0, vim.api.nvim_buf_line_count(bufnr), false, {})
  end)

  state.vis_start   = nil
  state.button_cols = nil
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  return true
end

-- ── Mutual exclusion ─────────────────────────────────────────────────

local function close_others(bufnr, active_key)
  for key, mod_name in pairs(MODS) do
    if key ~= active_key then
      local ok, mod = pcall(require, mod_name)
      if ok and is_panel_visible(mod, bufnr) then mod.remove_section(bufnr) end
    end
  end
end

local function make_toggle(key, mod_name, bufnr)
  return function()
    local ok, mod = pcall(require, mod_name)
    if not ok then return end
    if is_panel_visible(mod, bufnr) then
      mod.remove_section(bufnr)
    else
      close_others(bufnr, key)
      mod.render_section(bufnr)
    end
    M.update_tabbar(bufnr)
  end
end

-- ── CR: tab click or fall through to link follow ──────────────────────

local function handle_cr(bufnr)
  local state = get_state(bufnr)
  if not state.vis_start then return false end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum   = cursor[1]  -- 1-indexed
  local col    = cursor[2]  -- 0-indexed byte offset

  -- Tab bar occupies vis_start .. vis_start+2 (1-indexed)
  if lnum < state.vis_start or lnum > state.vis_start + 2 then return false end

  for _, btn in ipairs(state.button_cols or {}) do
    if col >= btn.from and col <= btn.to then
      make_toggle(btn.key, MODS[btn.key], bufnr)()
      return true
    end
  end
  -- Cursor is in the tab bar region but not over a button (gap between buttons)
  return true  -- still consume the CR to avoid stray line-opens
end

--- Public: called from ui.lua's follow-link button so a single tap on a tab
--- button activates it (cursor moves there on tap, then follow = activate).
function M.handle_cr(bufnr)
  return handle_cr(bufnr)
end

-- ── Write lifecycle ───────────────────────────────────────────────────
--
-- panels registers its autocmds LAST, so its BufWritePre fires after all
-- individual modules have already:
--   1. removed their sections
--   2. set their had_* flags
--
-- panels.BufWritePre captures which panel to restore, clears the modules'
-- had_* flags (so their BufWritePost is a no-op), then removes the tab bar.
--
-- panels.BufWritePost re-renders: tab bar first, then the active panel below.

local function on_write_pre(bufnr)
  local state = get_state(bufnr)

  state.active_to_restore = nil
  for key, mod_name in pairs(MODS) do
    local ok, mod = pcall(require, mod_name)
    if ok and mod._state[bufnr] then
      local flag = HAD_FLAGS[key]
      if mod._state[bufnr][flag] then
        state.active_to_restore = key
        mod._state[bufnr][flag] = false  -- suppress module's own BufWritePost re-render
      end
    end
  end

  state.had_tabbar = state.vis_start ~= nil or state.active_to_restore ~= nil
  M.remove_tabbar(bufnr)
end

local function on_write_post(bufnr)
  local state = get_state(bufnr)
  if not state.had_tabbar then return end
  state.had_tabbar = false

  local key = state.active_to_restore
  state.active_to_restore = nil

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    -- Skip if no window is currently showing this buffer (e.g. after :wq).
    -- Without this guard, render_section would scan the entire vault on a
    -- buffer the user has already closed, blocking input for seconds.
    if #vim.fn.win_findbuf(bufnr) == 0 then return end
    M.render_tabbar(bufnr)
    if key then
      local ok, mod = pcall(require, MODS[key])
      if ok then
        mod.render_section(bufnr)
        M.update_tabbar(bufnr)
      end
    end
  end)
end

-- ── Buffer setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local km = config.current.keymaps or {}

  -- Override the per-module toggle keymaps with coordinated versions
  vim.keymap.set("n", km.toggle_backlinks or "<leader>b",
    make_toggle("backlinks", MODS.backlinks, bufnr),
    { buffer = bufnr, silent = true, desc = "Logseq: toggle backlinks" })

  vim.keymap.set("n", "<leader>q",
    make_toggle("queries", MODS.queries, bufnr),
    { buffer = bufnr, silent = true, desc = "Logseq: toggle queries" })

  vim.keymap.set("n", km.toggle_ns_tree or "<leader>N",
    make_toggle("ns_tree", MODS.ns_tree, bufnr),
    { buffer = bufnr, silent = true, desc = "Logseq: toggle namespace tree" })

  -- Buffer-local <CR>: check tab bar first, fall through to link follow
  vim.keymap.set("n", "<CR>", function()
    if not handle_cr(bufnr) then
      require("logseq.links").follow()
    end
  end, { buffer = bufnr, silent = true, desc = "Logseq: follow link / activate panel tab" })

  -- NOTE: No <LeftMouse> override here.  A buffer-local <LeftMouse> mapping
  -- consumes ALL mouse clicks, including those on the winbar (journal buttons)
  -- and tabline (:wq) — those callbacks never fire when the mapping returns
  -- early.  Tab-bar activation is handled via <CR> (above) and the public
  -- M.handle_cr exposed to ui.lua's follow-link statusline button.

  local group = vim.api.nvim_create_augroup("LogseqPanels_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group, buffer = bufnr,
    callback = function(ev) on_write_pre(ev.buf) end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group, buffer = bufnr,
    callback = function(ev) on_write_post(ev.buf) end,
  })

  -- Block insert mode in the tab bar region
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group, buffer = bufnr,
    callback = function(ev)
      local st   = get_state(ev.buf)
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      if st.vis_start and lnum >= st.vis_start - 1 then
        vim.cmd("stopinsert")
        vim.notify("[logseq.nvim] Tab bar is read-only.", vim.log.levels.INFO)
      end
    end,
  })

  -- Re-anchor vis_start if content above the tab bar shifts its line number.
  -- TextChangedI is intentionally excluded: insert-mode edits can't reach the
  -- tab bar (InsertEnter guard above), so we only need to track normal-mode edits.
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group, buffer = bufnr,
    callback = function(ev)
      local st = get_state(ev.buf)
      if not st.vis_start then return end
      local top = find_tabbar_top(ev.buf, st.vis_start)
      if top then st.vis_start = top end
    end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group, buffer = bufnr,
    callback = function(ev) M._state[ev.buf] = nil end,
  })

  -- Initial render: tab bar only; no panel auto-opens on buffer load
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    M.render_tabbar(bufnr)
  end)
end

return M
