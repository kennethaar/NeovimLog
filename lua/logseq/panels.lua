--- logseq.nvim panel coordinator
--- Backlinks and namespace tree behave as exclusive tabs:
--- at most one is visible at a time.  This module owns all toggle
--- keymaps and is the only place that calls render_section, so mutual
--- exclusion is guaranteed without any cross-module imports inside the
--- individual panel modules.

local M = {}

local PANELS = {
  { key = "backlinks", mod = "logseq.backlinks"      },
  { key = "ns_tree",   mod = "logseq.namespace_tree" },
}

local function is_visible(mod, bufnr)
  local s = mod._state[bufnr]
  return s ~= nil and s.visible == true
end

local function close_others(bufnr, active_key)
  for _, p in ipairs(PANELS) do
    if p.key ~= active_key then
      local mod = require(p.mod)
      if is_visible(mod, bufnr) then
        mod.remove_section(bufnr)
      end
    end
  end
end

local function make_toggle(key, mod_name, bufnr)
  return function()
    local mod = require(mod_name)
    if is_visible(mod, bufnr) then
      mod.remove_section(bufnr)
    else
      close_others(bufnr, key)
      mod.render_section(bufnr)
    end
  end
end

M.close_others = close_others

--- Toggle a panel by key for the current buffer (called from winbar globals).
function M.toggle_key(key)
  local bufnr = vim.api.nvim_get_current_buf()
  for _, p in ipairs(PANELS) do
    if p.key == key then
      make_toggle(key, p.mod, bufnr)()
      return
    end
  end
end

--- Close all visible panels. Call before :wq so the buffer is clean and no
--- deferred render can re-dirty it between write and quit (E37).
function M.close_all(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  for _, p in ipairs(PANELS) do
    local ok, mod = pcall(require, p.mod)
    if ok and is_visible(mod, bufnr) then
      mod.remove_section(bufnr)
    end
  end
end

function M.setup_buf(bufnr)
  local km = require("logseq.config").current.keymaps or {}

  -- Override the keymaps set by individual modules so every toggle goes
  -- through the coordinator and enforces mutual exclusion.
  vim.keymap.set("n", km.toggle_backlinks or "<leader>b",
    make_toggle("backlinks", "logseq.backlinks", bufnr),
    { buffer = bufnr, silent = true, desc = "Logseq: toggle backlinks" })

  vim.keymap.set("n", km.toggle_ns_tree or "<leader>N",
    make_toggle("ns_tree", "logseq.namespace_tree", bufnr),
    { buffer = bufnr, silent = true, desc = "Logseq: toggle namespace tree" })

  -- Auto-render namespace tree (previously owned by namespace_tree.setup_buf).
  -- Runs after everything else is set up so other panels have a chance to
  -- register first (relevant for the is_visible checks).
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local ns_tree = require("logseq.namespace_tree")
    -- render_section is a no-op for non-namespace pages, so this is always safe.
    close_others(bufnr, "ns_tree")
    ns_tree.render_section(bufnr)
  end)
end

return M
