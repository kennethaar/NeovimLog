--- logseq.nvim entry point
--- Plugin activation, command registration, and autocmd setup.

local config = require("logseq.config")
local util = require("logseq.util")
local M = {}

local function is_vault_file(bufpath)
  return util.is_vault_file(bufpath, config.current.vault_path)
end

local function activate(bufnr)
  -- Default to current buffer if bufnr is 0 or nil
  bufnr = (bufnr == 0 or bufnr == nil) and vim.api.nvim_get_current_buf() or bufnr

  if vim.b[bufnr].logseq_active then return end
  vim.b[bufnr].logseq_active = true

  local modules = {
    "logseq.fold",
    "logseq.motions",
    "logseq.links",
    "logseq.ui",
    "logseq.editing",
    "logseq.zoom",
    "logseq.autosave",
    "logseq.backlinks",
    "logseq.queries",
    "logseq.namespace_tree",
    "logseq.panels",   -- must be last: overrides panel keymaps and owns auto-render
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

  -- Register keymaps with which-key if it is installed, so the user can
  -- discover every binding via the popup without reading the source or help.
  -- The pcall means this is a no-op on configs that don't have which-key.
  local ok_wk, wk = pcall(require, "which-key")
  if ok_wk then
    local km = config.current.keymaps
    wk.add({
      -- Block navigation
      { km.next_sibling,     desc = "Next sibling block",              buffer = bufnr, mode = "n" },
      { km.prev_sibling,     desc = "Previous sibling block",          buffer = bufnr, mode = "n" },
      { km.first_child,      desc = "First child block",               buffer = bufnr, mode = "n" },
      { km.parent,           desc = "Parent block",                    buffer = bufnr, mode = "n" },
      -- Block movement
      { km.move_down,        desc = "Move block down (with subtree)",  buffer = bufnr, mode = "n" },
      { km.move_up,          desc = "Move block up (with subtree)",    buffer = bufnr, mode = "n" },
      { km.promote,          desc = "Outdent block (with subtree)",    buffer = bufnr, mode = "n" },
      { km.demote,           desc = "Indent block (with subtree)",     buffer = bufnr, mode = "n" },
      -- Editing
      { km.new_sibling,      desc = "New sibling block below",         buffer = bufnr, mode = "n" },
      { km.todo_cycle,       desc = "Cycle TODO state",                buffer = bufnr, mode = "n" },
      -- Links and search
      { km.follow_link,      desc = "Follow link / open page",         buffer = bufnr, mode = "n" },
      { km.search_pages,     desc = "Search vault pages",              buffer = bufnr, mode = "n" },
      -- Panels and UI
      { km.toggle_backlinks, desc = "Toggle backlinks panel",          buffer = bufnr, mode = "n" },
      { km.fold_toggle,      desc = "Toggle fold",                     buffer = bufnr, mode = "n" },
      { km.help,             desc = "Open Logseq help",                buffer = bufnr, mode = "n" },
      -- Zoom
      { km.zoom_toggle,      desc = "Zoom into block (toggle)",        buffer = bufnr, mode = "n" },
      -- Fixed keymaps (not user-configurable but still worth showing)
      { "O",                 desc = "New sibling block above",         buffer = bufnr, mode = "n" },
      { "<Tab>",             desc = "Indent block",                    buffer = bufnr, mode = "n" },
      { "<S-Tab>",           desc = "Outdent block",                   buffer = bufnr, mode = "n" },
    })
  end
end

local function run_interactive_setup(opts, callback)
  vim.notify("[logseq.nvim] Vault not configured. Starting setup...", vim.log.levels.INFO)

  vim.ui.input({ prompt = "Enter Logseq Vault Path: ", completion = "dir" }, function(vault_input)
    if not vault_input or vault_input == "" then
      vim.notify("[logseq.nvim] Setup aborted. Vault path is required.", vim.log.levels.WARN)
      return
    end

    -- Strip surrounding quotes that users sometimes paste from Windows paths
    vault_input = vault_input:match('^["\'](.+)["\']$') or vault_input

    opts.vault_path = vault_input
    config.save_to_disk(vault_input, nil)
    callback(opts)
  end)
end

local function bootstrap(opts)
  if not config.setup(opts) then return end

  -- One-time global setup
  pcall(function() require("logseq.backlinks").setup_global() end)

  local group = vim.api.nvim_create_augroup("logseq_nvim", { clear = true })

  -- ── Commands (Namespaced for Best Practices) ──────────────────────

  vim.api.nvim_create_user_command("LogseqConfig", function()
    require("logseq.config_ui").open()
  end, { desc = "Open Logseq shortcuts & UI config" })

  vim.api.nvim_create_user_command("LogseqCalSync", function()
    local ok, cal = pcall(require, "logseq.calendar")
    if ok then cal.sync(true) else vim.notify("Calendar module not found", vim.log.levels.ERROR) end
  end, { desc = "Sync Logseq calendar" })

  vim.api.nvim_create_user_command("LogseqCalAdd", function()
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
  end, { desc = "Add a new calendar ICS URL" })

  vim.api.nvim_create_user_command("LogseqCalEdit", function()
    local function show_menu()
      local urls = config.current.calendar_urls or {}
      local items = vim.deepcopy(urls)
      table.insert(items, "[ + Add new URL ]")
      table.insert(items, "[ Done ]")

      vim.ui.select(items, { prompt = "Calendar URLs (select to remove):" }, function(choice)
        if not choice or choice == "[ Done ]" then return end

        if choice == "[ + Add new URL ]" then
          vim.cmd("LogseqCalAdd")
          return
        end

        -- Selected an existing URL — confirm removal
        vim.ui.select({ "Remove this URL", "Cancel" }, { prompt = choice }, function(action)
          if action == "Remove this URL" and config.remove_calendar_url(choice) then
            vim.notify("[logseq.nvim] URL removed.", vim.log.levels.INFO)
          end
          show_menu()
        end)
      end)
    end

    show_menu()
  end, { desc = "Edit/Remove existing calendar URLs" })

  vim.api.nvim_create_user_command("LogseqCalRemind", function()
    local current = config.current.reminder_minutes
    local prompt_msg = current
      and string.format("Reminder lead time (currently %d min, 0 to disable): ", current)
      or "Minutes before meeting to remind (default: 3): "

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
  end, { desc = "Set calendar reminder lead time" })

  vim.api.nvim_create_user_command("LogseqToday", function()
    local dir = vim.fs.joinpath(config.current.vault_path, "journals")
    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
    
    local filepath = vim.fs.joinpath(dir, os.date(config.current.journal_format) .. ".md")

    if util.normalize(vim.api.nvim_buf_get_name(0)) == util.normalize(filepath) then return end
    if vim.bo.modified then vim.cmd("write") end

    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    -- edit is synchronous; buffer is ready immediately. vim.schedule ensures we don't block.
    vim.schedule(function() activate(0) end)
  end, { desc = "Open today's Logseq journal" })

  vim.api.nvim_create_user_command("LogseqNewPage", function(cmd_opts)
    local function create_page(input)
      if not input or input == "" then return end
      local filename = util.encode_filename(input)
      local filepath = vim.fs.joinpath(config.current.vault_path, "pages", filename)
      
      vim.cmd("edit " .. vim.fn.fnameescape(filepath))
      vim.schedule(function() activate(0) end)
    end

    if not cmd_opts.args or cmd_opts.args == "" then
      vim.ui.input({ prompt = "Page name: " }, create_page)
    else
      create_page(cmd_opts.args)
    end
  end, { nargs = "?", desc = "Create a new Logseq page" })

  -- ── Autocmds ──────────────────────────────────────────────────────

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufpath = vim.api.nvim_buf_get_name(ev.buf)
      if not is_vault_file(bufpath) then return end

      activate(ev.buf)

      if ev.event == "BufNewFile" then
        vim.schedule(function()
          local ok, templates = pcall(require, "logseq.templates")
          if ok then templates.apply_template(ev.buf) end
        end)
      end

      -- WARNING: If cal.sync() is blocking, this will lag your editor every time you open a file.
      vim.schedule(function()
        pcall(function() require("logseq.calendar").sync() end)
      end)
    end,
  })

  -- Catch buffers re-entered that might have bypassed BufReadPost
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufpath = vim.api.nvim_buf_get_name(ev.buf)
      if not is_vault_file(bufpath) then return end
      activate(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      pcall(function() require("logseq.parser").invalidate_cache(ev.buf) end)
    end,
  })

  -- ── First-Run Logic ───────────────────────────────────────────────
  
  -- Replaced intrusive popup with silent default + helpful notification
  if config.current.reminder_minutes == nil then
    config.set_reminder_minutes(3)
    vim.schedule(function()
      vim.notify("[logseq.nvim] Meeting reminders defaulted to 3 min. Use :LogseqCalRemind to change.", vim.log.levels.INFO)
    end)
  end
end

function M.setup(opts)
  opts = opts or {}
  if not opts.vault_path or opts.vault_path == "" then
    local saved = config.load_global_vault_path()
    if saved and saved ~= "" then
      opts.vault_path = saved
      bootstrap(opts)
    else
      run_interactive_setup(opts, bootstrap)
    end
  else
    bootstrap(opts)
  end
end

return M

