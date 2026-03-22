--- logseq.nvim entry point
--- Plugin activation, command registration, and autocmd setup.

local config = require("logseq.config")
local util = require("logseq.util")
local M = {}

local function is_vault_file(bufpath)
  return util.is_vault_file(bufpath, config.current.vault_path)
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
    "logseq.backlinks",
    "logseq.queries",
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

-- ── Inbox flush ───────────────────────────────────────────────────────────────
-- termux-url-opener writes shared URLs here; Neovim merges them into the
-- journal buffer so autosave never overwrites externally-appended content.
local inbox_path = vim.fn.expand("~/.local/share/nvim/journal_inbox.md")

local function flush_inbox(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- Only merge into today's journal
  local cfg = config.current
  if not cfg or not cfg.vault_path then return end
  local today_path = cfg.vault_path .. "/journals/" .. os.date(cfg.journal_format) .. ".md"
  if util.normalize(vim.api.nvim_buf_get_name(bufnr)) ~= util.normalize(today_path) then return end

  -- Atomically claim the inbox so concurrent writes are not lost
  local tmp_path = inbox_path .. ".processing"
  if not os.rename(inbox_path, tmp_path) then return end  -- nothing to do

  local f = io.open(tmp_path, "r")
  if not f then return end
  local content = f:read("*all")
  f:close()
  os.remove(tmp_path)

  local lines = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  if #lines == 0 then return end

  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
  vim.notify("[logseq.nvim] " .. #lines .. " item(s) added from shared inbox.", vim.log.levels.INFO)
end

local function flush_inbox_current()
  flush_inbox(vim.api.nvim_get_current_buf())
end

local function bootstrap(opts)
  if not config.setup(opts) then return end

  -- One-time global autocmd: refresh backlinks panels when any vault file is written
  pcall(function() require("logseq.backlinks").setup_global() end)

  local group = vim.api.nvim_create_augroup("logseq_nvim", { clear = true })

  -- ── Commands ──────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("Calsync", function()
    local ok, cal = pcall(require, "logseq.calendar")
    if ok then cal.sync(true) else vim.notify("Calendar module not found", vim.log.levels.ERROR) end
  end, {})

  vim.api.nvim_create_user_command("Caladd", function()
    require("logseq.calendar").prompt_add_calendar_urls({
      on_done = function() require("logseq.calendar").sync(true) end,
    })
  end, {})

  vim.api.nvim_create_user_command("CalEdit", function()
    local function show_menu()
      local urls = config.current.calendar_urls or {}
      local items = {}
      for _, url in ipairs(urls) do
        table.insert(items, url)
      end
      table.insert(items, "[ + Add new URL ]")
      table.insert(items, "[ Done ]")

      vim.ui.select(items, { prompt = "Calendar URLs (select to remove):" }, function(choice)
        if not choice or choice == "[ Done ]" then return end

        if choice == "[ + Add new URL ]" then
          vim.ui.input({ prompt = "Paste Calendar ICS URL: " }, function(input)
            if not input or input == "" then
              show_menu()
              return
            end
            if config.add_calendar_url(input) then
              vim.notify("[logseq.nvim] URL added.", vim.log.levels.INFO)
            else
              vim.notify("[logseq.nvim] URL already exists or failed to save.", vim.log.levels.WARN)
            end
            show_menu()
          end)
          return
        end

        -- Selected an existing URL — confirm removal
        vim.ui.select(
          { "Remove this URL", "Cancel" },
          { prompt = choice },
          function(action)
            if action == "Remove this URL" then
              if config.remove_calendar_url(choice) then
                vim.notify("[logseq.nvim] URL removed.", vim.log.levels.INFO)
              end
            end
            show_menu()
          end
        )
      end)
    end

    show_menu()
  end, {})

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

  vim.api.nvim_create_user_command("LogseqToday", function()
    local dir = config.current.vault_path .. "/journals"
    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
    local filepath = dir .. "/" .. os.date(config.current.journal_format) .. ".md"

    if util.normalize(vim.api.nvim_buf_get_name(0)) == util.normalize(filepath) then return end
    if vim.bo.modified then vim.cmd("write") end

    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    vim.defer_fn(function() activate(vim.api.nvim_get_current_buf()) end, 50)
  end, {})

  -- (audit #28) LogseqNewPage — create a new page with proper namespace encoding
  local function open_page(page_name)
    local filepath = config.current.vault_path .. "/pages/" .. util.encode_filename(page_name)
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    vim.defer_fn(function() activate(vim.api.nvim_get_current_buf()) end, 50)
  end

  vim.api.nvim_create_user_command("LogseqNewPage", function(cmd_opts)
    local page_name = cmd_opts.args
    if not page_name or page_name == "" then
      vim.ui.input({ prompt = "Page name: " }, function(input)
        if not input or input == "" then return end
        open_page(input)
      end)
      return
    end
    open_page(page_name)
  end, { nargs = "?" })

  -- ── Autocmds ──────────────────────────────────────────────────────

  -- Auto-activate on markdown files inside the vault
  -- (audit #22) Calendar sync only on BufReadPost/BufNewFile, NOT BufEnter
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

      vim.schedule(function() flush_inbox(ev.buf) end)
      pcall(function() require("logseq.calendar").sync() end)
    end,
  })

  -- Activate on BufEnter without calendar sync (audit #22)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufpath = vim.api.nvim_buf_get_name(ev.buf)
      if not is_vault_file(bufpath) then return end
      activate(ev.buf)
    end,
  })

  -- Reload files changed externally; also flush shared-URL inbox on focus
  vim.o.autoread = true
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    group = group,
    callback = function()
      vim.cmd("checktime")
      flush_inbox_current()
    end,
  })

  -- Clean up parser cache on buffer unload
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      pcall(function() require("logseq.parser").invalidate_cache(ev.buf) end)
    end,
  })

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
