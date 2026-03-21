--- logseq.nvim reminders
--- Schedules vim.notify popups N minutes before calendar events.
--- Provides a winbar countdown string for the next upcoming meeting.
--- All timers are cancelled and re-created on each calendar sync.

local M = {}

M._state = {
  timers    = {},   -- Active timer IDs (for cleanup on re-sync)
  events    = {},   -- Parsed events: { summary, start_epoch, end_epoch, time_str }[]
  float_win = nil,  -- Current reminder float window (if open)
  float_buf = nil,  -- Current reminder float buffer
  tick_timer = nil, -- 30-second winbar refresh timer
  hl_ns     = vim.api.nvim_create_namespace("logseq_active_event"),
}

-- ── Helpers ───────────────────────────────────────────────────────────

--- Parse "HH:MM" into an epoch timestamp for today.
---@param hhmm string  e.g. "09:45"
---@return integer|nil  epoch seconds, or nil if unparseable
local function hhmm_to_epoch(hhmm)
  local h, m = hhmm:match("^(%d%d):(%d%d)$")
  if not h then return nil end
  local now = os.date("*t")
  return os.time({
    year = now.year, month = now.month, day = now.day,
    hour = tonumber(h), min = tonumber(m), sec = 0,
  })
end

--- Format a number of seconds into a human-readable duration.
---@param seconds integer
---@return string
local function format_duration(seconds)
  if seconds < 60 then return "less than 1 min" end
  local mins = math.floor(seconds / 60)
  if mins < 60 then return mins .. " min" end
  local hrs = math.floor(mins / 60)
  local remaining_mins = mins % 60
  if remaining_mins == 0 then return hrs .. " hr" end
  return hrs .. " hr " .. remaining_mins .. " min"
end

-- ── Dismissable Float Popup ──────────────────────────────────────────

--- Show a floating reminder window that stays until the user presses <CR> or q.
---@param summary string  event name
---@param time_str string  e.g. "09:45"
local function show_reminder_float(summary, time_str)
  -- Close any existing reminder float first
  if M._state.float_win and vim.api.nvim_win_is_valid(M._state.float_win) then
    vim.api.nvim_win_close(M._state.float_win, true)
  end

  local lead = require("logseq.config").current.reminder_minutes or 3

  -- Build content lines — ✖ sits in top-right of line 0
  local body_text = "  ☕ " .. lead .. " minutes until " .. summary .. " (" .. time_str .. ")"
  local width = math.max(#body_text + 6, 44)

  -- Pad the close button to the far right of line 0
  local close_line = string.rep(" ", width - 4) .. "(:q) ✖"
  width = math.max(width, #close_line + 2)

  local ok_padding = string.rep(" ", math.floor((width - 4) / 2))

  local lines = {
    close_line,
    "",
    "  ☕ " .. lead .. " minutes until",
    "     " .. summary .. " (" .. time_str .. ")",
    "",
    ok_padding .. "[OK]",
    "",
  }

  local height = #lines

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"

  local ui_width = vim.o.columns
  local ui_height = vim.o.lines
  local row = math.floor((ui_height - height) / 2)
  local col = math.floor((ui_width - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Reminder ",
    title_pos = "center",
  })

  M._state.float_win = win
  M._state.float_buf = buf

  -- Force normal mode (in case we were in insert mode when the timer fired)
  vim.cmd("stopinsert")

  -- Highlights
  local hl_close_col = #close_line - #"(:q) ✖"
  vim.api.nvim_buf_add_highlight(buf, -1, "Comment", 0, hl_close_col, hl_close_col + #"(:q)")
  vim.api.nvim_buf_add_highlight(buf, -1, "DiagnosticError", 0, #close_line - #"✖", -1)
  vim.api.nvim_buf_add_highlight(buf, -1, "WarningMsg", 2, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, -1, "Bold", 3, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, -1, "Special", 5, 0, -1)

  -- Dismiss function
  local function dismiss()
    if M._state.float_win and vim.api.nvim_win_is_valid(M._state.float_win) then
      vim.api.nvim_win_close(M._state.float_win, true)
    end
    M._state.float_win = nil
    M._state.float_buf = nil
  end

  -- Keyboard dismiss — map generously so nothing gets stuck
  local dismiss_keys = { "<CR>", "q", "<Esc>", "<Space>", "<BS>" }
  for _, key in ipairs(dismiss_keys) do
    vim.keymap.set("n", key, dismiss, { buffer = buf, nowait = true, silent = true })
  end

  -- Mouse dismiss — clicking anywhere in the float closes it
  vim.keymap.set("n", "<LeftRelease>", dismiss, { buffer = buf, nowait = true, silent = true })

  -- Also close if the user leaves the float window
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(dismiss)
    end,
  })
end

-- ── Winbar Countdown ─────────────────────────────────────────────────

--- Returns a string for the winbar showing current and/or next meeting.
--- Called by ui.lua on every winbar redraw.
---@return string  e.g. "Now: Standup (12 min left)  │  ☕ Lunch in 45 min" or ""
function M.next_meeting_str()
  local now = os.time()
  local current_event = nil
  local next_event = nil
  local next_diff = math.huge

  for _, ev in ipairs(M._state.events) do
    -- Currently active: started and not ended
    if ev.end_epoch and ev.start_epoch <= now and ev.end_epoch > now then
      current_event = ev
    end
    -- Upcoming: starts in the future, pick the closest
    local diff = ev.start_epoch - now
    if diff > 0 and diff < next_diff then
      next_diff = diff
      next_event = ev
    end
  end

  if not current_event and not next_event then return "" end

  local parts = {}

  if current_event then
    local remaining = current_event.end_epoch - now
    table.insert(parts, "Now: " .. current_event.summary .. " (" .. format_duration(remaining) .. " left)")
  end

  if next_event then
    local icon = next_diff <= 300 and "⚠" or "☕"
    table.insert(parts, icon .. " " .. next_event.summary .. " in " .. format_duration(next_diff))
  end

  return table.concat(parts, "  │  ")
end

-- ── Active Event Highlight ───────────────────────────────────────────

--- Highlight the line of the currently-active event in the buffer.
--- An event is "active" when now is between its start and end time.
function M.update_highlight()
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- Clear previous highlights
  vim.api.nvim_buf_clear_namespace(bufnr, M._state.hl_ns, 0, -1)

  local now = os.time()
  local active_summary = nil

  -- Find the currently-active event
  for _, ev in ipairs(M._state.events) do
    if ev.start_epoch <= now and ev.end_epoch and ev.end_epoch > now then
      active_summary = ev.summary
      break
    end
  end

  if not active_summary then return end

  -- Search the buffer for the line containing this event's summary
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    -- Match calendar event lines like "  - 09:45-11:00 Meps Nordic PM"
    if line:match("^%s*%- ") and line:find(active_summary, 1, true) then
      vim.api.nvim_buf_set_extmark(bufnr, M._state.hl_ns, i - 1, 0, {
        end_row = i - 1,
        end_col = #line,
        hl_group = "CurSearch",
        priority = 50,
      })
      break
    end
  end
end

--- Start the 30-second tick timer that forces winbar redraws.
--- Uses a self-rescheduling one-shot pattern: the timer fires once, updates state,
--- then reschedules itself only if there are still relevant events.
local function start_tick_timer()
  if M._state.tick_timer then
    vim.fn.timer_stop(M._state.tick_timer)
    M._state.tick_timer = nil
  end

  local function tick(_)
    vim.schedule(function()
      if not M._state.tick_timer then return end  -- cancelled between fire and schedule
      M._state.tick_timer = nil

      pcall(M.update_highlight)
      pcall(vim.cmd, "redraw!")

      local now = os.time()
      for _, ev in ipairs(M._state.events) do
        if ev.start_epoch > now or (ev.end_epoch and ev.end_epoch > now) then
          start_tick_timer()  -- still relevant — reschedule
          return
        end
      end
      -- No more relevant events — stop ticking
    end)
  end

  M._state.tick_timer = vim.fn.timer_start(30000, tick)
end

-- ── Timer Scheduling ─────────────────────────────────────────────────

--- Cancel all pending reminder timers.
function M.cancel_all()
  for _, tid in ipairs(M._state.timers) do
    vim.fn.timer_stop(tid)
  end
  M._state.timers = {}
end

--- Schedule reminders for a list of calendar events.
--- Called by calendar.lua after a successful sync.
--- Winbar countdown ALWAYS works. Popup reminders only fire if reminder_minutes > 0.
---@param events table[]  raw event objects from the Python JSON: { uid, summary, time_str, is_allday }
function M.schedule(events)
  -- Cancel any previous timers (prevents duplicates on re-sync)
  M.cancel_all()
  M._state.events = {}

  local now = os.time()

  -- 1. Always parse events for winbar countdown (regardless of reminder_minutes)
  for _, ev in ipairs(events) do
    if ev.is_allday or not ev.time_str then goto next_ev end
    local start_hhmm, end_hhmm = ev.time_str:match("^(%d%d:%d%d)%-(%d%d:%d%d)$")
    start_hhmm = start_hhmm or ev.time_str:match("^(%d%d:%d%d)$")
    if not start_hhmm then goto next_ev end
    local start_epoch = hhmm_to_epoch(start_hhmm)
    if not start_epoch then goto next_ev end
    table.insert(M._state.events, {
      summary     = ev.summary,
      start_epoch = start_epoch,
      end_epoch   = end_hhmm and hhmm_to_epoch(end_hhmm) or nil,
      time_str    = start_hhmm,
    })
    ::next_ev::
  end

  table.sort(M._state.events, function(a, b) return a.start_epoch < b.start_epoch end)

  -- 2. Start winbar tick timer if we have any future or currently-active events
  local needs_timer = false
  for _, ev in ipairs(M._state.events) do
    if ev.start_epoch > now or (ev.end_epoch and ev.end_epoch > now) then
      needs_timer = true
      break
    end
  end
  if needs_timer then start_tick_timer() end
  -- Highlight the currently-active event and force redraw
  M.update_highlight()
  pcall(vim.cmd, "redraw!")

  -- 3. Schedule popup reminders only if reminder_minutes is configured
  local config = require("logseq.config").current
  local lead_minutes = config.reminder_minutes
  if not lead_minutes or lead_minutes <= 0 then return end

  for _, ev in ipairs(M._state.events) do
    local remind_at = ev.start_epoch - (lead_minutes * 60)
    local delay_sec = remind_at - now

    if delay_sec > 0 then
      local delay_ms = delay_sec * 1000
      local summary = ev.summary
      local time_str = ev.time_str
      local tid = vim.fn.timer_start(delay_ms, function()
        vim.schedule(function()
          show_reminder_float(summary, time_str)
        end)
      end)
      table.insert(M._state.timers, tid)
    end
  end
end

return M
