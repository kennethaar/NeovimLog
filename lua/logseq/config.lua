local M = {}

M.defaults = {
  vault_path = nil,
  calendar_urls = {},
  reminder_minutes = 3,
  journal_format = "%Y_%m_%d",
  indent_size = 2,
  fold_on_open = false,
  enable_link_search = true,
  keymaps = {
    next_sibling = "<leader>j",
    prev_sibling = "<leader>k",
    first_child  = "<leader>J",
    parent       = "<leader>K",
    move_down    = "<A-Down>",
    move_up      = "<A-Up>",
    promote      = "<<",
    demote       = ">>",
    new_sibling  = "o",
    fold_toggle  = "za",
    follow_link  = "<CR>",
    toggle_backlinks = "<leader>b",
  },
}

M.current = {}

-- Dynamically generate the save path inside the user's vault
local function get_save_path(vault_path)
  -- Saves as a hidden file in the root of the Logseq graph
  return vault_path .. "/.logseq_nvim.json"
end

-- Load saved user data from the vault
local function load_from_vault(vault_path)
  local path = get_save_path(vault_path)
  if vim.fn.filereadable(path) == 1 then
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local ok, data = pcall(vim.json.decode, content)
      if ok and type(data) == "table" then
        return data
      end
    end
  end
  return {}
end

-- Add a new calendar URL to disk and current session
function M.add_calendar_url(url)
  if not url or url == "" then return false end
  if not M.current.vault_path then return false end
  
  local data = load_from_vault(M.current.vault_path)
  data.calendar_urls = data.calendar_urls or M.current.calendar_urls or {}
  
  -- Prevent duplicates
  for _, existing_url in ipairs(data.calendar_urls) do
    if existing_url == url then return false end
  end
  
  -- Add to persistent data and runtime config
  table.insert(data.calendar_urls, url)
  M.current.calendar_urls = data.calendar_urls
  
  -- Save back to JSON inside the vault
  local path = get_save_path(M.current.vault_path)
  local f = io.open(path, "w")
  if f then
    f:write(vim.json.encode(data))
    f:close()
    return true
  end
  return false
end

-- Save user data to disk (Called by the interactive setup wizard)
function M.save_to_disk(vault_path, calendar_urls)
  local data = load_from_vault(vault_path)
  if calendar_urls then
    data.calendar_urls = calendar_urls
  end
  
  local path = get_save_path(vault_path)
  local f = io.open(path, "w")
  if f then
    f:write(vim.json.encode(data))
    f:close()
  end
end

function M.setup(opts)
  -- 1. We MUST have the vault path from the user's config first
  local vault_path = opts and opts.vault_path
  
  if not vault_path or vault_path == "" then
    return false -- Triggers the interactive setup in init.lua
  end

  vault_path = vim.fn.resolve(vim.fn.expand(vault_path)):gsub("\\", "/")

  -- 2. Now that we know where the vault is, load the calendar URLs from inside it
  local vault_config = load_from_vault(vault_path)
  
  -- Merge order: Defaults <- Vault Saved Config <- Setup Options
  M.current = vim.tbl_deep_extend("force", {}, M.defaults, vault_config, opts or {})
  M.current.vault_path = vault_path

  if vim.fn.isdirectory(M.current.vault_path) == 0 then
    vim.notify("[logseq.nvim] Vault not found: " .. M.current.vault_path, vim.log.levels.WARN)
  end

  return true
end

return M