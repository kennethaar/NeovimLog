local M = {}
M.current = {}
M.defaults = {
  vault_path = nil, calendar_urls = {}, reminder_minutes = 3, journal_format = "%Y_%m_%d", indent_size = 2, fold_on_open = false, enable_link_search = true,
  keymaps = { next_sibling = "<leader>j", prev_sibling = "<leader>k", first_child = "<leader>J", parent = "<leader>K", move_down = "<A-Down>", move_up = "<A-Up>", promote = "<<", demote = ">>", new_sibling = "o", fold_toggle = "za", zoom_block = "<leader>Z", follow_link = "<CR>", toggle_backlinks = "<leader>b", todo_cycle = "<C-t>", help = "hh", search_pages = "<C-k>", rename_page = "<leader>rn", query_builder = "<leader>Q" },
  winbar_buttons = { rename = true, search = true, backlinks = true, ns_tree = true, calsync = true, close = true, page_tabline = true },
  bottombar_buttons = { follow_link = true, fold_toggle = true, todo_cycle = true, indent = true, unindent = true, move_up = true, move_down = true },
}

local function handle_json(path, data)
  if not data then
    if vim.fn.filereadable(path) ~= 1 then return {} end
    local f = io.open(path, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    local ok, decoded = pcall(vim.json.decode, content)
    return (ok and type(decoded) == "table") and decoded or {}
  else
    local ok, encoded = pcall(vim.json.encode, data)
    if not ok then return false end
    local f = io.open(path, "w")
    if f then f:write(encoded); f:close(); return true end
    return false
  end
end

local function g_path() return vim.fs.joinpath(vim.fn.stdpath("data"), "logseq_nvim_global.json") end
local function v_path(v) return vim.fs.joinpath(v, ".logseq_nvim.json") end

function M.load_global_vault_path() return handle_json(g_path()).vault_path end
function M.save_global_vault_path(vp) handle_json(g_path(), {vault_path = vp}) end

function M.add_calendar_url(url)
  if not url or url == "" or not M.current.vault_path then return false end
  local data = handle_json(v_path(M.current.vault_path))
  data.calendar_urls = data.calendar_urls or {}
  if vim.list_contains(data.calendar_urls, url) then return false end
  table.insert(data.calendar_urls, url)
  M.current.calendar_urls = vim.deepcopy(data.calendar_urls)
  return handle_json(v_path(M.current.vault_path), data)
end

function M.remove_calendar_url(url)
  if not url or url == "" or not M.current.vault_path then return false end
  local data = handle_json(v_path(M.current.vault_path))
  local original = #(data.calendar_urls or {})
  data.calendar_urls = vim.iter(data.calendar_urls or {}):filter(function(v) return v ~= url end):totable()
  if #data.calendar_urls == original then return false end
  M.current.calendar_urls = vim.deepcopy(data.calendar_urls)
  return handle_json(v_path(M.current.vault_path), data)
end

function M.set_reminder_minutes(mins)
  M.current.reminder_minutes = mins
  if not M.current.vault_path then return end
  local data = handle_json(v_path(M.current.vault_path))
  data.reminder_minutes = mins
  handle_json(v_path(M.current.vault_path), data)
end

function M.save_keymaps_and_ui(keymaps, winbar_buttons, bottombar_buttons)
  M.current.keymaps = vim.tbl_deep_extend("force", M.current.keymaps or {}, keymaps)
  M.current.winbar_buttons = vim.deepcopy(winbar_buttons)
  M.current.bottombar_buttons = vim.deepcopy(bottombar_buttons)
  if not M.current.vault_path then return end
  local data = handle_json(v_path(M.current.vault_path))
  data.keymaps = M.current.keymaps
  data.winbar_buttons = M.current.winbar_buttons
  data.bottombar_buttons = M.current.bottombar_buttons
  handle_json(v_path(M.current.vault_path), data)
end

function M.save_to_disk(vault_path, calendar_urls)
  local data = handle_json(v_path(vault_path))
  if calendar_urls then data.calendar_urls = vim.deepcopy(calendar_urls) end
  handle_json(v_path(vault_path), data)
  M.save_global_vault_path(vault_path)
end

function M.setup(opts)
  local vp = opts and opts.vault_path
  if not vp or vp == "" then return false end
  vp = require("logseq.util").normalize(vp)
  M.current = vim.tbl_deep_extend("force", {}, M.defaults, handle_json(v_path(vp)), opts or {})
  M.current.vault_path = vp
  if vim.fn.isdirectory(vp) ~= 0 then M.save_global_vault_path(vp) end
  return true
end

return M
