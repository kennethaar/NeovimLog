--- logseq.nvim calendar sync
--- Fetches ICS calendar data via Python and maintains a "- # Calendar"
--- block in today's journal with chronological ordering.

local util = require("logseq.util")
local M = {}

-- ── URL collection prompt ─────────────────────────────────────────────

--- Interactively prompt the user to add one or more calendar ICS URLs.
--- Shared by M.sync (when no URLs configured) and the :Caladd command.
---@param opts { first_prompt?: string, on_abort?: function, on_done?: function }
function M.prompt_add_calendar_urls(opts)
  opts = opts or {}
  local function ask(count)
    local prompt = count == 0
      and (opts.first_prompt or "Paste Calendar ICS URL (empty to cancel): ")
      or string.format("Saved %d! Paste another URL (empty to finish): ", count)

    vim.ui.input({ prompt = prompt }, function(input)
      if not input or input == "" then
        if count > 0 then
          vim.notify(string.format("[logseq.nvim] %d calendars saved!", count), vim.log.levels.INFO)
          if opts.on_done then opts.on_done(count) end
        elseif opts.on_abort then
          opts.on_abort()
        end
        return
      end

      if require("logseq.config").add_calendar_url(input) then
        ask(count + 1)
      else
        vim.notify("[logseq.nvim] URL already exists or failed to save.", vim.log.levels.WARN)
        ask(count)
      end
    end)
  end
  ask(0)
end

-- ── Buffer manipulation ───────────────────────────────────────────────

local function apply_events_to_buffer(buf, events)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cal_start_idx = nil

  for i, line in ipairs(lines) do
    if line:match("^%- # Calendar") then
      cal_start_idx = i
      break
    end
  end

  if not cal_start_idx then
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "- # Calendar" })
    cal_start_idx = #lines + 2
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  local cal_end_idx = cal_start_idx + 1
  while cal_end_idx <= #lines do
    if lines[cal_end_idx]:match("^[^%s]") then break end
    cal_end_idx = cal_end_idx + 1
  end

  -- Extract existing blocks
  local existing_blocks = {}
  local existing_by_uid = {}
  local orphans = {}
  local current_block = nil

  for i = cal_start_idx + 1, cal_end_idx - 1 do
    local line = lines[i]

    if line:match("^  %- ") then
      if current_block then table.insert(existing_blocks, current_block) end
      current_block = { lines = { line }, uid = nil }
    elseif current_block then
      table.insert(current_block.lines, line)
      local uid = line:match("^%s+id::%s*(.+)$")
      if uid then
        current_block.uid = uid
        existing_by_uid[uid] = current_block
      end
    else
      table.insert(orphans, line)
    end
  end

  if current_block then
    table.insert(existing_blocks, current_block)
    if current_block.uid then existing_by_uid[current_block.uid] = current_block end
  end

  -- Build new sorted list
  local new_calendar_lines = {}
  local active_uids = {}

  for _, line in ipairs(orphans) do
    table.insert(new_calendar_lines, line)
  end

  -- Active events (chronological order from Python)
  for _, ev in ipairs(events) do
    active_uids[ev.uid] = true
    local formatted_title = ev.is_allday
      and string.format("  - (Heldags) %s", ev.summary)
      or string.format("  - %s %s", ev.time_str, ev.summary)

    local block = existing_by_uid[ev.uid]
    if block then
      local current_title = block.lines[1]
      if not current_title:match("~~.*~~") and current_title ~= formatted_title then
        block.lines[1] = formatted_title
      end
      for _, line in ipairs(block.lines) do
        table.insert(new_calendar_lines, line)
      end
    else
      table.insert(new_calendar_lines, formatted_title)
      table.insert(new_calendar_lines, string.format("    id:: %s", ev.uid))
    end
  end

  -- Cancelled/removed events at bottom
  for _, block in ipairs(existing_blocks) do
    if block.uid and not active_uids[block.uid] then
      local current_title = block.lines[1]
      if current_title:match("^%s*%- ") and not current_title:match("~~.*~~") then
        local indent_part, content = current_title:match("^(%s*%- )(.*)$")
        block.lines[1] = string.format("%s~~%s~~", indent_part, content)
      end
      for _, line in ipairs(block.lines) do
        table.insert(new_calendar_lines, line)
      end
    elseif not block.uid then
      for _, line in ipairs(block.lines) do
        table.insert(new_calendar_lines, line)
      end
    end
  end

  vim.api.nvim_buf_set_lines(buf, cal_start_idx, cal_end_idx - 1, false, new_calendar_lines)
end

-- ── Sync ──────────────────────────────────────────────────────────────

function M.sync(force)
  local target_bufnr = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(target_bufnr)
  local cfg = require("logseq.config").current

  local today_filename = os.date(cfg.journal_format) .. ".md"
  local today_filepath = cfg.vault_path .. "/journals/" .. today_filename

  local norm_current = util.normalize(current_file)
  local norm_today = util.normalize(today_filepath)
  local is_today_journal = (norm_current == norm_today)

  -- Guard: silent abort for non-journal pages unless forced
  if not is_today_journal and not force then return end

  if not is_today_journal then
    vim.notify("[logseq.nvim] Warning: Syncing calendar into a non-today journal.", vim.log.levels.WARN)
  end

  -- URL check
  local urls = cfg.calendar_urls
  if not urls or #urls == 0 then
    vim.schedule(function()
      M.prompt_add_calendar_urls({
        first_prompt = "No calendars. Paste ICS URL (empty to cancel): ",
        on_abort = function()
          vim.notify("[logseq.nvim] Sync aborted. No URL provided.", vim.log.levels.WARN)
        end,
        on_done = function() M.sync(force) end,
      })
    end)
    return
  end

  -- Python check
  local py_bin = vim.fn.executable("python3") == 1 and "python3" or "python"
  if vim.fn.executable(py_bin) == 0 then
    vim.notify("[logseq.nvim] Python is required for calendar sync.", vim.log.levels.ERROR)
    return
  end

  local py_script_path = vim.fn.resolve(vim.fn.expand(vim.fn.stdpath("config") .. "/lua/logseq/ical_parser.py"))

  if is_today_journal then
    vim.notify("[logseq.nvim] Fetching calendar data...", vim.log.levels.INFO)
  end

  local urls_json = vim.json.encode(urls)
  local stderr_buf = {}

  vim.fn.jobstart({ py_bin, py_script_path, urls_json }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then return end

      local ok, events = pcall(vim.json.decode, table.concat(data, ""))
      if not ok or not events then
        vim.schedule(function() vim.notify("Failed reading valid JSON from Python.", vim.log.levels.ERROR) end)
        return
      end

      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(target_bufnr) then return end

        apply_events_to_buffer(target_bufnr, events)

        local rok, reminders = pcall(require, "logseq.reminders")
        if rok then reminders.schedule(events) end

        if is_today_journal then
          vim.notify("[logseq.nvim] Calendar synced successfully!", vim.log.levels.INFO)
        end
      end)
    end,
    on_stderr = function(_, data)
      if data then vim.list_extend(stderr_buf, data) end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          local err_str = table.concat(stderr_buf, "\n"):gsub("%s+$", "")
          local msg = err_str ~= "" and err_str or ("exit code " .. code)
          vim.notify("[logseq.nvim] Calendar sync failed:\n" .. msg, vim.log.levels.ERROR)
        end)
      end
    end,
  })
end

return M
