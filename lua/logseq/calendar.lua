local M = {}
local config_json_path = vim.fn.stdpath("config") .. "/config.json"
-- Pass på at denne stien stemmer overens med der du la python-filen:
local py_script_path = vim.fn.stdpath("config") .. "/lua/logseq/ical_parser.py"

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
  local urls = {}
  local i = 1
  while true do
    local url = vim.fn.input(string.format("Kalender-URL %d (tom = ferdig): ", i))
    if url == "" then break end
    table.insert(urls, url)
    i = i + 1
  end

  if #urls == 0 then return nil end
  local data = { calendars = urls }
  local f = io.open(config_json_path, "w")
  if f then
    f:write(vim.json.encode(data))
    f:close()
  end
  return data
end

local function apply_events_to_buffer(buf, events)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cal_start_idx = nil

  -- 1. Finn "- # Calendar"-blokken
  for i, line in ipairs(lines) do
    if line:match("^%- # Calendar") then
      cal_start_idx = i
      break
    end
  end

  -- Opprett blokken hvis den ikke finnes
  if not cal_start_idx then
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "- # Calendar" })
    cal_start_idx = #lines + 2
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  -- 2. Kartlegg eksisterende hendelser basert på UID
  local existing_uids = {}
  local i = cal_start_idx + 1
  while i <= #lines do
    local line = lines[i]
    -- Hvis vi treffer en linje uten innrykk (og det ikke er Calendar-linjen), har vi forlatt blokken
    if line:match("^[^%s]") and not line:match("^%- # Calendar") then break end
    
    -- Se etter dobbelkolon id:: egenskap
    local uid = line:match("^%s+id::%s*(.+)$")
    if uid then
      -- Møtetittelen ligger normalt på linjen over UID-en
      existing_uids[uid] = { title_idx = i - 1, prop_idx = i }
    end
    i = i + 1
  end

  -- 3. Behandle innkommende hendelser
  local new_lines_to_append = {}
  local active_uids_today = {}

  for _, ev in ipairs(events) do
    active_uids_today[ev.uid] = true
    local formatted_title = ev.is_allday and string.format("  - (Heldags) %s", ev.summary) 
                                          or string.format("  - %s %s", ev.time_str, ev.summary)

    if existing_uids[ev.uid] then
      -- Smart Update av eksisterende møte
      local title_line_idx = existing_uids[ev.uid].title_idx
      local current_title = lines[title_line_idx]
      -- Kun oppdater hvis tittelen er endret og den ikke har strikethrough (er kansellert tidligere)
      if not current_title:match("~~.*~~") and current_title ~= formatted_title then
        vim.api.nvim_buf_set_lines(buf, title_line_idx - 1, title_line_idx, false, { formatted_title })
      end
    else
      -- Legg til nytt møte
      table.insert(new_lines_to_append, formatted_title)
      table.insert(new_lines_to_append, string.format("    id:: %s", ev.uid))
    end
  end

  -- 4. Merk kansellerte/fjernede møter med Strikethrough
  for uid, loc in pairs(existing_uids) do
    if not active_uids_today[uid] then
      local title_line_idx = loc.title_idx
      local current_title = lines[title_line_idx]
      -- Legg til strikethrough hvis det ikke allerede er der
      if current_title:match("^%s*%- ") and not current_title:match("~~.*~~") then
        local indent, content = current_title:match("^(%s*%- )(.*)$")
        local struck_title = string.format("%s~~%s~~", indent, content)
        vim.api.nvim_buf_set_lines(buf, title_line_idx - 1, title_line_idx, false, { struck_title })
      end
    end
  end

  -- 5. Skriv de nye møtene til bunnen av Calendar-blokken
  if #new_lines_to_append > 0 then
    local insert_idx = cal_start_idx
    while insert_idx < #lines do
      if lines[insert_idx + 1] and lines[insert_idx + 1]:match("^[^%s]") then break end
      insert_idx = insert_idx + 1
    end
    vim.api.nvim_buf_set_lines(buf, insert_idx, insert_idx, false, new_lines_to_append)
  end

  print("Kalender syncet!")
end

function M.sync()
  -- Streng sjekk: Bare sync hvis vi er i dagens journal
  local current_file = vim.api.nvim_buf_get_name(0)
  -- Juster denne stringen til å matche formatet du har på journalfilene dine!
  local today_str = os.date("%Y_%m_%d") 
  if not current_file:match(today_str) then
    return
  end

  local conf = get_calendar_config()
  if not conf then
    conf = M.setup()
    if not conf then return end
  end

  print("Syncer kalender...")
  local urls_json = vim.json.encode(conf.calendars)
  
  -- "python" (i stedet for "python3") siden du er på Windows
  vim.fn.jobstart({ "python", py_script_path, urls_json }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data and data[1] and data[1] ~= "" then
        local ok, events = pcall(vim.json.decode, table.concat(data, ""))
        if ok and events then
          vim.schedule(function()
            apply_events_to_buffer(vim.api.nvim_get_current_buf(), events)
          end)
        else
          vim.schedule(function() print("Feil ved lesing av kalenderdata fra Python.") end)
        end
      end
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          print("Python-feil: " .. table.concat(data, " "))
        end)
      end
    end,
  })
end

return M