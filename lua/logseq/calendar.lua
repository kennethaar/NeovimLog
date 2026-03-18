-- =========================================================================
-- calendar.lua — Kalender-sync for Neovim journal
-- Ren Lua iCal-parser, bruker curl for henting.
-- Plasseres i: ~/.config/nvim/lua/calendar.lua (eller tilsvarende)
-- =========================================================================
local M = {}

local config_json_path = vim.fn.stdpath("config") .. "/config.json"

-- =========================================================================
-- Config: Les eller opprett config.json med kalender-URLer
-- =========================================================================
local function get_calendar_config()
  if vim.fn.filereadable(config_json_path) == 1 then
    local f = io.open(config_json_path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local ok, data = pcall(vim.json.decode, content)
      if ok and data and data.calendars and #data.calendars > 0 then
        return data
      end
    end
  end
  return nil
end

function M.setup()
  vim.api.nvim_echo({{ "\nKalender-oppsett: Legg til iCal/ICS-URLer.\n", "WarningMsg" }}, false, {})
  vim.api.nvim_echo({{ "Trykk Enter uten tekst når du er ferdig.\n", "Normal" }}, false, {})

  local urls = {}
  local i = 1
  while true do
    local url = vim.fn.input(string.format("Kalender-URL %d (tom = ferdig): ", i))
    if url == "" then break end
    table.insert(urls, url)
    i = i + 1
  end

  if #urls == 0 then
    vim.api.nvim_echo({{ "\nIngen URLer lagt til. Kalender-sync deaktivert.\n", "WarningMsg" }}, false, {})
    return nil
  end

  local data = { calendars = urls }
  local f = io.open(config_json_path, "w")
  if f then
    f:write(vim.json.encode(data))
    f:close()
  end
  vim.api.nvim_echo({{ string.format("\n%d kalender(e) lagret i config.json!\n", #urls), "Normal" }}, false, {})
  return data
end

-- =========================================================================
-- iCal-parser: hent VEVENT-blokker for en gitt dato
-- =========================================================================
local function parse_ical_events(ical_text, target_date)
  local found = {}
  local target_ymd = target_date -- "YYYYMMDD"

  for vevent in ical_text:gmatch("BEGIN:VEVENT(.-)END:VEVENT") do
    local summary = vevent:match("SUMMARY[^:]*:([^\r\n]+)") or "(Uten tittel)"
    local dtstart_raw = vevent:match("DTSTART[^:]*:([^\r\n]+)") or ""
    local dtend_raw = vevent:match("DTEND[^:]*:([^\r\n]+)") or ""
    local description = vevent:match("DESCRIPTION[^:]*:([^\r\n]+)") or ""
    local location = vevent:match("LOCATION[^:]*:([^\r\n]+)") or ""
    local uid = vevent:match("UID[^:]*:([^\r\n]+)") or ""

    -- Rens escaped tegn i iCal
    summary = summary:gsub("\\,", ","):gsub("\\;", ";"):gsub("\\n", " ")
    description = description:gsub("\\,", ","):gsub("\\;", ";"):gsub("\\n", "\n")
    location = location:gsub("\\,", ","):gsub("\\;", ";")

    -- Parse dato fra DTSTART
    local start_date = dtstart_raw:match("^(%d%d%d%d%d%d%d%d)")
    if not start_date then
      start_date = dtstart_raw:match("(%d%d%d%d%d%d%d%d)")
    end

    if start_date == target_ymd then
      local start_time = dtstart_raw:match("%d%d%d%d%d%d%d%dT(%d%d%d%d%d%d)")
      local end_time = dtend_raw:match("%d%d%d%d%d%d%d%dT(%d%d%d%d%d%d)")
      local is_allday = (start_time == nil)

      local time_str = ""
      if start_time then
        local sh, sm = start_time:sub(1,2), start_time:sub(3,4)
        local eh, em = "", ""
        if end_time then
          eh, em = end_time:sub(1,2), end_time:sub(3,4)
        end

        local utc_offset = tonumber(os.date("%z"):sub(1,3)) or 0
        local start_h = (tonumber(sh) + utc_offset) % 24
        if eh ~= "" then
          local end_h = (tonumber(eh) + utc_offset) % 24
          time_str = string.format("%02d:%s-%02d:%s", start_h, sm, end_h, em)
        else
          time_str = string.format("%02d:%s", start_h, sm)
        end
      end

      table.insert(found, {
        summary = summary,
        time_str = time_str,
        is_allday = is_allday,
        description = description,
        location = location,
        uid = uid,
      })
    end
  end

  table.sort(found, function(a, b)
    if a.is_allday ~= b.is_allday then return a.is_allday end
    return a.time_str < b.time_str
  end)

  return found
end

-- =========================================================================
-- Hent iCal-data via curl (asynkront)
-- =========================================================================
local function fetch_ical(url, callback)
  vim.fn.jobstart({ "curl", "-s", "-L", "-A", "Mozilla/5.0", url }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        callback(table.concat(data, "\n"))
      end
    end,
    on_stderr = function(_, data)
      if data and data[1] ~= "" then
        vim.schedule(function()
          vim.api.nvim_echo({{ "Kalender-feil: " .. table.concat(data, " "), "ErrorMsg" }}, false, {})
        end)
      end
    end,
  })
end

-- =========================================================================
-- Skriv hendelser under # Calendar i gjeldende buffer
-- =========================================================================
local function write_events_to_buffer(all_events)
  if #all_events == 0 then
    vim.api.nvim_echo({{ "Ingen kalenderhendelser i dag.", "Normal" }}, false, {})
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Finn "# Calendar"-linjen
  local calendar_line = nil
  for i, line in ipairs(lines) do
    if line:match("^# Calendar") then
      calendar_line = i
      break
    end
  end

  if not calendar_line then
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "# Calendar", "" })
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:match("^# Calendar") then
        calendar_line = i
        break
      end
    end
  end

  -- Sjekk hva som allerede finnes under # Calendar (unngå duplikater)
  local existing_text = table.concat(
    vim.api.nvim_buf_get_lines(buf, calendar_line, -1, false), "\n"
  )

  local new_lines = {}
  local added = 0
  for _, ev in ipairs(all_events) do
    if not existing_text:find(ev.summary, 1, true) then
      local entry
      if ev.is_allday then
        entry = "- (Heldags) " .. ev.summary
      else
        entry = "- " .. ev.time_str .. " " .. ev.summary
      end
      table.insert(new_lines, entry)

      if ev.location ~= "" then
        table.insert(new_lines, "  - Sted: " .. ev.location)
      end

      added = added + 1
    end
  end

  if added > 0 then
    vim.api.nvim_buf_set_lines(buf, calendar_line, calendar_line, false, new_lines)
    vim.api.nvim_echo({{ string.format("Kalender: %d hendelse(r) lagt til.", added), "Normal" }}, false, {})
  else
    vim.api.nvim_echo({{ "Kalender: Ingen nye hendelser.", "Normal" }}, false, {})
  end
end

-- =========================================================================
-- Hovedfunksjon: sync kalender for i dag
-- =========================================================================
function M.sync()
  local conf = get_calendar_config()
  if not conf then
    -- Første gang: spør om URLer
    conf = M.setup()
    if not conf then return end
  end

  local target_date = os.date("%Y%m%d")
  local all_events = {}
  local pending = #conf.calendars

  if pending == 0 then return end

  vim.api.nvim_echo({{ "Syncer kalender...", "Normal" }}, false, {})

  for _, url in ipairs(conf.calendars) do
    fetch_ical(url, function(ical_text)
      local events = parse_ical_events(ical_text, target_date)
      for _, ev in ipairs(events) do
        table.insert(all_events, ev)
      end
      pending = pending - 1
      if pending == 0 then
        vim.schedule(function()
          table.sort(all_events, function(a, b)
            if a.is_allday ~= b.is_allday then return a.is_allday end
            return a.time_str < b.time_str
          end)
          write_events_to_buffer(all_events)
        end)
      end
    end)
  end
end

return M