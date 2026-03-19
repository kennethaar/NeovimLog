local config = require("logseq.config")
local M = {}

local function normalize(p)
  if not p or p == "" then return "" end
  local resolved = vim.fn.resolve(vim.fn.expand(p)):gsub("\\", "/")
  if vim.fn.has("win32") == 1 then resolved = resolved:lower() end
  return resolved
end

local function is_vault_file(bufpath)
  local vault = config.current.vault_path
  if not vault or vault == "" then return false end
  return normalize(bufpath):sub(1, #vault) == normalize(vault)
end

local function activate(bufnr)
  if vim.b[bufnr].logseq_active then return end
  vim.b[bufnr].logseq_active = true

  local modules = {
    "logseq.fold",
    "logseq.motions",
    "logseq.links",
    "logseq.ui",
    "logseq.editing",
    "logseq.autosave",
    "logseq.backlinks"
  }

  for _, mod in ipairs(modules) do
    local ok, m = pcall(require, mod)
    if ok and m.setup_buf then
      m.setup_buf(bufnr)
    end
  end

  if config.current.enable_link_search then
    pcall(function() require("logseq.page_search").setup_buf(bufnr) end)
  end
end

local function run_interactive_setup(opts, callback)
  vim.notify("Logseq vault not configured. Starting setup...", vim.log.levels.INFO)
  
  vim.ui.input({ prompt = "Enter Logseq Vault Path: ", completion = "dir" }, function(vault_input)
    if not vault_input or vault_input == "" then
      vim.notify("Setup aborted. Vault path is required.", vim.log.levels.WARN)
      return
    end
    
    opts.vault_path = vault_input
    config.save_to_disk(vault_input, nil)
    callback(opts)
  end)
end

local function bootstrap(opts)
  if not config.setup(opts) then return end

  local group = vim.api.nvim_create_augroup("logseq_nvim", { clear = true })

  -- Command 1: Force Sync
  vim.api.nvim_create_user_command("Calsync", function()
    local ok, cal = pcall(require, "logseq.calendar")
    if ok then cal.sync(true) else vim.notify("Calendar module not found", vim.log.levels.ERROR) end
  end, {})

  -- Command 2: Add Calendar URL (Renamed to Caladd)
  vim.api.nvim_create_user_command("Caladd", function()
    local function ask_for_url(count)
      local prompt_msg = count == 0 
        and "Paste Calendar ICS URL (empty to cancel): " 
        or string.format("Saved %d! Paste another URL (empty to finish): ", count)

      vim.ui.input({ prompt = prompt_msg }, function(input)
        if not input or input == "" then
          if count > 0 then
            vim.notify(string.format("[logseq.nvim] %d calendars saved! Starting sync...", count), vim.log.levels.INFO)
            require("logseq.calendar").sync(true)
          end
          return
        end
        
        if config.add_calendar_url(input) then
          ask_for_url(count + 1)
        else
          vim.notify("[logseq.nvim] URL already exists or failed to save.", vim.log.levels.WARN)
          ask_for_url(count)
        end
      end)
    end

    ask_for_url(0) 
  end, {})

  -- Command 3: Change reminder lead time
  vim.api.nvim_create_user_command("Calremind", function()
    local current = config.current.reminder_minutes
    local prompt_msg = current
      and string.format("Reminder lead time (currently %d min, 0 to disable): ", current)
      or "How many minutes before a meeting should I remind you? (default: 3): "

    vim.ui.input({ prompt = prompt_msg }, function(input)
      if not input or input == "" then
        if not current then
          config.set_reminder_minutes(3)
          vim.notify("[logseq.nvim] Reminders set to 3 minutes.", vim.log.levels.INFO)
        end
        return
      end
      local mins = tonumber(input)
      if not mins or mins < 0 then
        vim.notify("[logseq.nvim] Invalid number.", vim.log.levels.WARN)
        return
      end
      config.set_reminder_minutes(mins)
      if mins == 0 then
        vim.notify("[logseq.nvim] Reminders disabled.", vim.log.levels.INFO)
        pcall(function() require("logseq.reminders").cancel_all() end)
      else
        vim.notify(string.format("[logseq.nvim] Reminders set to %d minutes.", mins), vim.log.levels.INFO)
      end
    end)
  end, {})

  -- Command 4: Jump to Today's Journal
  vim.api.nvim_create_user_command("LogseqToday", function()
    local dir = config.current.vault_path .. "/journals"
    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
    local filepath = dir .. "/" .. os.date(config.current.journal_format) .. ".md"
    
    if normalize(vim.api.nvim_buf_get_name(0)) == normalize(filepath) then return end
    if vim.bo.modified then vim.cmd("write") end
    
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    vim.defer_fn(function() activate(vim.api.nvim_get_current_buf()) end, 50)
  end, {})

  -- Auto-activate on markdown files inside the vault (Refactored for flatter logic)
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufpath = vim.api.nvim_buf_get_name(ev.buf)
      
      -- Guard clause: exit early if not in vault
      if not is_vault_file(bufpath) then return end 

      activate(ev.buf)
      
      -- Template Injection for new files
      if ev.event == "BufNewFile" then
        vim.schedule(function()
          local ok, templates = pcall(require, "logseq.templates")
          if ok then templates.apply_template(ev.buf) end
        end)
      end

      pcall(function() require("logseq.calendar").sync() end) 
    end,
  })

  -- First-run: ask for reminder lead time if never configured
  if config.current.reminder_minutes == nil then
    vim.defer_fn(function()
      vim.ui.input({
        prompt = "How many minutes before a meeting should I remind you? (default: 3): ",
      }, function(input)
        local mins = 3
        if input and input ~= "" then
          mins = tonumber(input) or 3
        end
        config.set_reminder_minutes(mins)
        if mins > 0 then
          vim.notify(string.format("[logseq.nvim] Reminders set to %d minutes. Change with :Calremind", mins), vim.log.levels.INFO)
        else
          vim.notify("[logseq.nvim] Reminders disabled. Enable with :Calremind", vim.log.levels.INFO)
        end
      end)
    end, 500)  -- Small delay so it doesn't collide with other startup prompts
  end
end

function M.setup(opts)
  opts = opts or {}
  if not opts.vault_path or opts.vault_path == "" then
    run_interactive_setup(opts, bootstrap)
  else
    bootstrap(opts)
  end
end

return M