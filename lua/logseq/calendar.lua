--- logseq.nvim calendar sync
--- Fetches ICS calendar data via Python and maintains a "- # Calendar"
--- block in today's journal with chronological ordering.

local util = require("logseq.util")
local M = {}

-- ── Buffer manipulation ───────────────────────────────────────────────

local function apply_events_to_buffer(buf, events)
  if not vim.api.nvim_buf_is_valid(buf) then return end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cal_start_idx = nil

  for i, line in ipairs(lines) do
    if line:match("^%- # Calendar") then
      cal_start_idx = i
      break
    end
  end

  if not cal_start_idx then
    -- Append header if missing
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

  -- 0-indexed API update
  vim.api.nvim_buf_set_lines(buf, cal_start_idx, cal_end_idx - 1, false, new_calendar_lines)
end

-- ── Sync ──────────────────────────────────────────────────────────────

function M.sync(force)
  local target_bufnr = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(target_bufnr)
  local cfg = require("logseq.config").current

  local today_filename = os.date(cfg.journal_format) .. ".md"
  -- Use joinpath to prevent double-slash issues
  local today_filepath = vim.fs.joinpath(cfg.vault_path, "journals", today_filename)

  local norm_current = util.normalize(current_file)
  local norm_today = util.normalize(today_filepath)
  local is_today_journal = (norm_current == norm_today)

  -- Guard: silent abort for non-journal pages unless forced
  if not is_today_journal and not force then return end

  if not is_today_journal and force then
    vim.notify("[logseq.nvim] Warning: Syncing calendar into a non-today journal.", vim.log.levels.WARN)
  end

  -- URL check
  local urls = cfg.calendar_urls
  if not urls or #urls == 0 then
    -- Only prompt if the user explicitly called the command. Don't prompt on BufReadPost.
    if force then
      vim.cmd("LogseqCalAdd")
    end
    return
  end

  -- Python check
  local py_bin = vim.fn.executable("python3") == 1 and "python3" or "python"
  if vim.fn.executable(py_bin) == 0 then
    if force then vim.notify("[logseq.nvim] Python is required for calendar sync.", vim.log.levels.ERROR) end
    return
  end

  -- Safely resolve script path regardless of plugin manager
  local py_script_paths = vim.api.nvim_get_runtime_file("lua/logseq/ical_parser.py", false)
  if #py_script_paths == 0 then
    vim.notify("[logseq.nvim] Could not locate ical_parser.py", vim.log.levels.ERROR)
    return
  end
  local py_script_path = py_script_paths[1]

  if is_today_journal and force then
    vim.notify("[logseq.nvim] Fetching calendar data...", vim.log.levels.INFO)
  end

  local urls_json = vim.json.encode(urls)
  local stdout_output = {}
  local stderr_output = {}

  -- Detangled and fixed jobstart block
  vim.fn.jobstart({ py_bin, py_script_path, urls_json }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do table.insert(stdout_output, line) end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do table.insert(stderr_output, line) end
      end
    end,
    on_exit = function(_, code)
      -- Handle errors first
      if code ~= 0 then
        local err_str = table.concat(stderr_output, "\n")
        if err_str:match("%S") then
          vim.notify("Python Error:\n" .. err_str, vim.log.levels.ERROR)
        else
          vim.notify("[logseq.nvim] Python script exited with error code: " .. code, vim.log.levels.ERROR)
        end
        return
      end

      -- If successful, process the data safely
      local raw_json = table.concat(stdout_output, "")
      if raw_json == "" then return end

      local ok, events = pcall(vim.json.decode, raw_json)
      if not ok or not events then
        vim.notify("Failed reading valid JSON from Python.", vim.log.levels.ERROR)
        return
      end

      -- Update UI on the main thread
      vim.schedule(function()
        apply_events_to_buffer(target_bufnr, events)
        
        local rok, reminders = pcall(require, "logseq.reminders")
        if rok then reminders.schedule(events) end
        
        if is_today_journal and force then
          vim.notify("[logseq.nvim] Calendar synced successfully!", vim.log.levels.INFO)
        end
      end)
    end,
  })
end

return M

