--- logseq.nvim configuration
--- Manages defaults, runtime config, and persistent vault-local storage.

local M = {}

M.current = {} -- populated by M.setup(); exists here so require-time reads don't error

M.defaults = {
  vault_path = nil,
  calendar_urls = {},
  favorites = {},
  reminder_minutes = 3,
  journal_format = "%Y_%m_%d",
  indent_size = 2,
  fold_on_open = false,
  enable_link_search = true,
  keymaps = {
    next_sibling     = "<leader>j",
    prev_sibling     = "<leader>k",
    first_child      = "<leader>J",
    parent           = "<leader>K",
    move_down        = "<A-Down>",
    move_up          = "<A-Up>",
    promote          = "<<",
    demote           = ">>",
    new_sibling      = "o",
    fold_toggle      = "za",
    follow_link      = "<CR>",
    toggle_backlinks = "<leader>b",
    todo_cycle       = "<C-t>",
    help             = "hh",
    search_pages     = "<C-k>",
  },
  winbar_buttons = {
    rename    = true,
    search    = true,
    backlinks = true,
    queries   = true,
    calsync   = true,
    close     = true,
  },
  bottombar_buttons = {
    follow_link = true,
    fold_toggle = true,
    todo_cycle  = true,
    indent      = true,
    unindent    = true,
    move_up     = true,
    move_down   = true,
  },
}

-- ── Vault-local persistence ───────────────────────────────────────────

local function get_save_path(vault_path)
  return vault_path .. "/.logseq_nvim.json"
end

local function load_from_vault(vault_path)
  local path = get_save_path(vault_path)
  if vim.fn.filereadable(path) ~= 1 then return {} end

  local f = io.open(path, "r")
  if not f then return {} end

  local content = f:read("*a")
  f:close()

  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then return data end
  return {}
end

local function save_data(vault_path, data)
  local path = get_save_path(vault_path)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(vim.json.encode(data))
  f:close()
  return true
end

-- ── Public API ────────────────────────────────────────────────────────

--- Add a new calendar URL to disk and current session.
---@param url string
---@return boolean
function M.add_calendar_url(url)
  if not url or url == "" then return false end
  if not M.current.vault_path then return false end

  local data = load_from_vault(M.current.vault_path)
  data.calendar_urls = data.calendar_urls or M.current.calendar_urls or {}

  for _, existing_url in ipairs(data.calendar_urls) do
    if existing_url == url then return false end
  end

  table.insert(data.calendar_urls, url)
  M.current.calendar_urls = data.calendar_urls
  return save_data(M.current.vault_path, data)
end

--- Remove a calendar URL from disk and current session.
---@param url string
---@return boolean
function M.remove_calendar_url(url)
  if not url or url == "" then return false end
  if not M.current.vault_path then return false end

  local data = load_from_vault(M.current.vault_path)
  data.calendar_urls = data.calendar_urls or M.current.calendar_urls or {}

  local found = false
  local new_urls = {}
  for _, existing_url in ipairs(data.calendar_urls) do
    if existing_url == url then
      found = true
    else
      table.insert(new_urls, existing_url)
    end
  end

  if not found then return false end
  data.calendar_urls = new_urls
  M.current.calendar_urls = new_urls
  return save_data(M.current.vault_path, data)
end

--- Persist and update reminder lead time (audit #1: was missing entirely).
---@param mins integer
function M.set_reminder_minutes(mins)
  M.current.reminder_minutes = mins
  if not M.current.vault_path then return end

  local data = load_from_vault(M.current.vault_path)
  data.reminder_minutes = mins
  save_data(M.current.vault_path, data)
end

--- Persist keymap and UI visibility settings.
---@param keymaps table
---@param winbar_buttons table
---@param bottombar_buttons table
function M.save_keymaps_and_ui(keymaps, winbar_buttons, bottombar_buttons)
  M.current.keymaps = vim.tbl_deep_extend("force", M.current.keymaps or {}, keymaps)
  M.current.winbar_buttons = winbar_buttons
  M.current.bottombar_buttons = bottombar_buttons

  if not M.current.vault_path then return end
  local data = load_from_vault(M.current.vault_path)
  data.keymaps = M.current.keymaps
  data.winbar_buttons = M.current.winbar_buttons
  data.bottombar_buttons = M.current.bottombar_buttons
  save_data(M.current.vault_path, data)
end

--- Save user data to disk (called by the interactive setup wizard).
---@param vault_path string
---@param calendar_urls string[]|nil
function M.save_to_disk(vault_path, calendar_urls)
  local data = load_from_vault(vault_path)
  if calendar_urls then
    data.calendar_urls = calendar_urls
  end
  save_data(vault_path, data)
end

--- Initialize configuration. Returns false if vault_path is missing.
---@param opts table|nil
---@return boolean
function M.setup(opts)
  local vault_path = opts and opts.vault_path
  if not vault_path or vault_path == "" then return false end

  local util = require("logseq.util")
  vault_path = util.normalize(vault_path)

  local vault_config = load_from_vault(vault_path)

  -- Merge order: Defaults <- Vault Saved Config <- Setup Options
  M.current = vim.tbl_deep_extend("force", {}, M.defaults, vault_config, opts or {})
  M.current.vault_path = vault_path

  if vim.fn.isdirectory(M.current.vault_path) == 0 then
    vim.notify("[logseq.nvim] Vault not found: " .. M.current.vault_path, vim.log.levels.WARN)
  end

  return true
end

--- Toggle a page name in the favorites list.
--- Returns true if added, false if removed.
---@param name string
---@return boolean
function M.toggle_favorite(name)
  if not M.current.vault_path then return false end
  local data = load_from_vault(M.current.vault_path)
  data.favorites = data.favorites or M.current.favorites or {}

  local found_idx
  for i, f in ipairs(data.favorites) do
    if f == name then found_idx = i; break end
  end

  local added
  if found_idx then
    table.remove(data.favorites, found_idx)
    added = false
  else
    table.insert(data.favorites, name)
    added = true
  end

  M.current.favorites = data.favorites
  save_data(M.current.vault_path, data)
  return added
end

--- Return the current favorites list.
---@return string[]
function M.get_favorites()
  return M.current.favorites or {}
end

return M
