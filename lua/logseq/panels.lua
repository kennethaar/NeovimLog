--- logseq.nvim panel coordinator
--- Backlinks / Queries / Namespace tree are exclusive panels — only one visible
--- at a time.  The active panel is shown in a section appended to the buffer.
---
--- Tab buttons live in the statusline (%@callback@ syntax) so they are
--- single-tap on mobile and never interact with buffer content or the write
--- lifecycle.  The statusline expression is re-evaluated by Neovim on every
--- redraw; toggle operations call redrawstatus for immediate feedback.

local M = {}
M._state = {} -- bufnr → { active_to_restore }

local config = require("logseq.config")

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

-- Short labels for the statusline tab buttons
local LABELS = { backlinks = "Links", queries = "Query", ns_tree = "NS" }

-- ── Helpers ───────────────────────────────────────────────────────────

--- Show a brief message in the command line for 2 seconds.
local function flash_msg(msg)
  vim.api.nvim_echo({{ msg, "Normal" }}, false, {})
  vim.defer_fn(function() vim.api.nvim_echo({{"", "Normal"}}, false, {}) end, 2000)
end

local function get_state(bufnr)
  if not M._state[bufnr] then
    M._state[bufnr] = { active_to_restore = nil }
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
  local tabs = { { key = "backlinks" } }
  if has_query_file(bufnr)    then table.insert(tabs, { key = "queries" }) end
  if is_namespace_page(bufnr) then table.insert(tabs, { key = "ns_tree" }) end
  return tabs
end

-- ── Statusline tab buttons ─────────────────────────────────────────────
-- Evaluated via %{%v:lua.require('logseq.panels').statusline_tabs()%} on every
-- statusline refresh.  Cheap: only reads in-memory state.

function M.statusline_tabs()
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.b[bufnr].logseq_active then return "" end

  local tabs = get_tabs(bufnr)
  if #tabs == 0 then return "" end

  local active = nil
  for key, mod_name in pairs(MODS) do
    local ok, mod = pcall(require, mod_name)
    if ok and is_panel_visible(mod, bufnr) then active = key; break end
  end

  local parts = {}
  for _, tab in ipairs(tabs) do
    local label = LABELS[tab.key]
    local hl    = tab.key == active and "%#Title#" or "%#Comment#"
    parts[#parts + 1] = hl .. "%@v:lua.logseq_panel_" .. tab.key .. "@[" .. label .. "]%X%#StatusLine#"
  end
  return table.concat(parts, " ") .. "  "
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
    local turning_on = not is_panel_visible(mod, bufnr)
    if turning_on then
      close_others(bufnr, key)
      mod.render_section(bufnr)
    else
      mod.remove_section(bufnr)
    end
    flash_msg(LABELS[key] .. (turning_on and " on" or " off"))
    vim.cmd("redrawstatus")
  end
end

--- Public toggle by key — called by the statusline click globals below.
function M.toggle(key)
  local bufnr = vim.api.nvim_get_current_buf()
  make_toggle(key, MODS[key], bufnr)()
end

-- Global statusline click callbacks registered once at module load.
-- Using pcall-require avoids a hard dependency cycle at load time.
_G.logseq_panel_backlinks = function() require("logseq.panels").toggle("backlinks") end
_G.logseq_panel_queries   = function() require("logseq.panels").toggle("queries")   end
_G.logseq_panel_ns_tree   = function() require("logseq.panels").toggle("ns_tree")   end

-- ── Write lifecycle ───────────────────────────────────────────────────
--
-- panels registers its autocmds LAST (init.lua), so its BufWritePre fires
-- after all individual modules have already:
--   1. removed their sections
--   2. set their had_* flags
--
-- panels.BufWritePre captures which panel to restore, clears the modules'
-- had_* flags (so their BufWritePost is a no-op), and takes over ordering.
--
-- panels.BufWritePost schedules restoration of the active panel.
-- The statusline tab state updates automatically via redrawstatus.

local function on_write_pre(bufnr)
  local state = get_state(bufnr)
  state.active_to_restore = nil

  for key, mod_name in pairs(MODS) do
    local ok, mod = pcall(require, mod_name)
    if ok and mod._state[bufnr] then
      local flag = HAD_FLAGS[key]
      if mod._state[bufnr][flag] then
        state.active_to_restore = key
        mod._state[bufnr][flag] = false  -- suppress module's own BufWritePost
      end
    end
  end
end

local function on_write_post(bufnr)
  local state = get_state(bufnr)
  local key = state.active_to_restore
  if not key then return end
  state.active_to_restore = nil

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    -- Skip if no window shows this buffer (e.g. after :wq) — prevents a
    -- vault scan on a buffer the user has already closed.
    if #vim.fn.win_findbuf(bufnr) == 0 then return end
    local ok, mod = pcall(require, MODS[key])
    if ok then mod.render_section(bufnr) end
    vim.cmd("redrawstatus")
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

  local group = vim.api.nvim_create_augroup("LogseqPanels_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group, buffer = bufnr,
    callback = function(ev) on_write_pre(ev.buf) end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group, buffer = bufnr,
    callback = function(ev) on_write_post(ev.buf) end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group, buffer = bufnr,
    callback = function(ev) M._state[ev.buf] = nil end,
  })
end

return M
