local M = {}

-- Safely pulls the entire event block (including user notes/sub-bullets) 
-- and rebuilds the Calendar section in strict chronological order.
local function apply_events_to_buffer(buf, events)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cal_start_idx = nil

  -- 1. Find the "- # Calendar" header
  for i, line in ipairs(lines) do
    if line:match("^%- # Calendar") then
      cal_start_idx = i
      break
    end
  end

  -- Create it if it doesn't exist
  if not cal_start_idx then
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "- # Calendar" })
    cal_start_idx = #lines + 2
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  -- 2. Find where the calendar block ends (the next root-level bullet)
  local cal_end_idx = cal_start_idx + 1
  while cal_end_idx <= #lines do
    -- If a line has text and DOES NOT start with whitespace, it's a new root block
    if lines[cal_end_idx]:match("^[^%s]") then break end
    cal_end_idx = cal_end_idx + 1
  end

  -- 3. Extract all existing blocks inside the Calendar section
  local existing_blocks = {}
  local existing_by_uid = {}
  local orphans = {} -- Catches empty lines or random text before the first event
  local current_block = nil

  for i = cal_start_idx + 1, cal_end_idx - 1 do
    local line = lines[i]
    
    -- Level 2 indent marks the start of an event
    if line:match("^  %- ") then
      if current_block then table.insert(existing_blocks, current_block) end
      current_block = { lines = { line }, uid = nil }
    elseif current_block then
      -- It's a property, a note, or a sub-bullet. Attach it to the current event.
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
  
  -- Catch the last block
  if current_block then
    table.insert(existing_blocks, current_block)
    if current_block.uid then existing_by_uid[current_block.uid] = current_block end
  end

  -- 4. Build the new sorted list of lines
  local new_calendar_lines = {}
  local active_uids = {}

  for _, line in ipairs(orphans) do
    table.insert(new_calendar_lines, line)
  end

  -- A. Add Active Events (in the exact chronological order Python gave us)
  for _, ev in ipairs(events) do
    active_uids[ev.uid] = true
    local formatted_title = ev.is_allday and string.format("  - (Heldags) %s", ev.summary)
                                          or string.format("  - %s %s", ev.time_str, ev.summary)

    local block = existing_by_uid[ev.uid]
    if block then
      -- Update title if changed and not cancelled
      local current_title = block.lines[1]
      if not current_title:match("~~.*~~") and current_title ~= formatted_title then
        block.lines[1] = formatted_title
      end
      -- Reinsert the entire block (which preserves UIDs and user notes!)
      for _, line in ipairs(block.lines) do 
        table.insert(new_calendar_lines, line) 
      end
    else
      -- Create brand new event block
      table.insert(new_calendar_lines, formatted_title)
      table.insert(new_calendar_lines, string.format("    id:: %s", ev.uid))
    end
  end

  -- B. Append Cancelled / Removed Events at the bottom of the list
  for _, block in ipairs(existing_blocks) do
    if block.uid and not active_uids[block.uid] then
      local current_title = block.lines[1]
      -- Strike it through if it isn't already
      if current_title:match("^%s*%- ") and not current_title:match("~~.*~~") then
        local indent, content = current_title:match("^(%s*%- )(.*)$")
        block.lines[1] = string.format("%s~~%s~~", indent, content)
      end
      for _, line in ipairs(block.lines) do 
        table.insert(new_calendar_lines, line) 
      end
    elseif not block.uid then
      -- If the user typed an indent without an ID, just keep it safely at the bottom
      for _, line in ipairs(block.lines) do 
        table.insert(new_calendar_lines, line) 
      end
    end
  end

  -- 5. Atomically replace the old calendar section with the new sorted section
  vim.api.nvim_buf_set_lines(buf, cal_start_idx, cal_end_idx - 1, false, new_calendar_lines)
end

function M.sync(force)
  local current_file = vim.api.nvim_buf_get_name(0)
  local today_str = os.date(require("logseq.config").current.journal_format) 
  
  if not current_file:match(today_str) then
    if force then
      vim.notify("[logseq.nvim] Warning: Syncing calendar into a non-today journal.", vim.log.levels.WARN)
    else
      return
    end
  end

  local urls = require("logseq.config").current.calendar_urls
  
  if not urls or #urls == 0 then 
    vim.schedule(function()
      local function ask_for_url(count)
        local prompt_msg = count == 0 
          and "No calendars. Paste ICS URL (empty to cancel): " 
          or string.format("Saved %d! Paste another URL (empty to sync): ", count)

        vim.ui.input({ prompt = prompt_msg }, function(input)
          if not input or input == "" then
            if count > 0 then
              vim.notify(string.format("[logseq.nvim] %d calendars saved! Starting sync...", count), vim.log.levels.INFO)
              M.sync(force)
            else
              vim.notify("[logseq.nvim] Sync aborted. No URL provided.", vim.log.levels.WARN)
            end
            return
          end
          
          if require("logseq.config").add_calendar_url(input) then
            ask_for_url(count + 1)
          else
            vim.notify("[logseq.nvim] URL already exists or failed to save.", vim.log.levels.WARN)
            ask_for_url(count)
          end
        end)
      end

      ask_for_url(0) 
    end)
    return 
  end

  local py_bin = vim.fn.executable("python3") == 1 and "python3" or "python"
  if vim.fn.executable(py_bin) == 0 then
    vim.notify("[logseq.nvim] Python is required for calendar sync.", vim.log.levels.ERROR)
    return
  end

  local py_script_path = vim.fn.resolve(vim.fn.expand(vim.fn.stdpath("config") .. "/lua/logseq/ical_parser.py"))

  vim.notify("[logseq.nvim] Fetching calendar data...", vim.log.levels.INFO)
  
  local urls_json = vim.json.encode(urls)
  
  vim.fn.jobstart({ py_bin, py_script_path, urls_json }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data and data[1] and data[1] ~= "" then
        local ok, events = pcall(vim.json.decode, table.concat(data, ""))
        if ok and events then
          vim.schedule(function() 
            apply_events_to_buffer(vim.api.nvim_get_current_buf(), events) 
            -- Feed parsed events to reminders for winbar countdown + popup timers
            local rok, reminders = pcall(require, "logseq.reminders")
            if rok then reminders.schedule(events) end
            vim.notify("[logseq.nvim] Calendar synced successfully!", vim.log.levels.INFO)
          end)
        else
          vim.schedule(function() vim.notify("Failed reading valid JSON from Python.", vim.log.levels.ERROR) end)
        end
      end
    end,
    on_stderr = function(_, data)
      local err_str = table.concat(data, "\n")
      if err_str:match("%S") then
          vim.schedule(function() vim.notify("Python Error:\n" .. err_str, vim.log.levels.ERROR) end)
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function() vim.notify("[logseq.nvim] Python script exited with error code: " .. code, vim.log.levels.ERROR) end)
      end
    end
  })
end

return M