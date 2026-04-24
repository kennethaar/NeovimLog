local M = {}
local util = require("logseq.util")
local parser = require("logseq.parser")
local config = require("logseq.config")
M._cache = {}
local is_indexing = false

-- ── Hjelpefunksjon: Batched prosessering ─────────────────────────────
-- Exported so query_engine.lua can also use it
function M.process_file_list_batched(files, on_file, on_complete, on_progress)
  local i = 0
  local BATCH = 20
  local function step()
    local active = 0
    local to_process = math.min(BATCH, #files - i)
    if to_process == 0 then
      if on_progress then on_progress(#files, #files) end
      return on_complete()
    end
    for _ = 1, to_process do
      i = i + 1
      active = active + 1
      on_file(files[i], i, function()
        active = active - 1
        if active == 0 then
          if on_progress then on_progress(i, #files) end
          vim.schedule(step)
        end
      end)
    end
  end
  vim.schedule(step)
end

-- ── State Management ────────────────────────────────────────────────
function M.invalidate(filepath)
  M._cache[util.normalize(filepath)] = nil
end

function M.get_parsed_file_async(filepath, callback)
  local uv = vim.uv or vim.loop
  local norm = util.normalize(filepath)
  uv.fs_stat(filepath, function(err, stat)
    if err or not stat then return callback(nil, nil) end
    
    local cached = M._cache[norm]
    if cached and cached.mtime == stat.mtime.sec then 
      return callback(cached.lines, cached.parsed) 
    end
    
    uv.fs_open(filepath, "r", 438, function(open_err, fd)
      if open_err then return callback(nil, nil) end
      uv.fs_read(fd, stat.size, 0, function(read_err, content)
        uv.fs_close(fd)
        if read_err or not content then return callback(nil, nil) end
        vim.schedule(function()
          local lines = vim.split(content, "\n", { plain = true })
          local parsed = parser.parse(lines)
          M._cache[norm] = { mtime = stat.mtime.sec, parsed = parsed, lines = lines }
          callback(lines, parsed)
        end)
      end)
    end)
  end)
end

-- ── Backlinks-logikk (Flattet ut) ───────────────────────────────────
function M.find_backlinks(page_name, exclude_file, on_complete, on_progress, iso_alias)
  if is_indexing then return end
  local vault = config.current.vault_path
  if not vault then return on_complete({}) end
  
  is_indexing = true
  local results = {}
  local norm_exclude = util.normalize(exclude_file)
  
  -- Vi søker etter råstrenger i Ripgrep (tryggere)
  local search_terms = { page_name:lower() }
  if iso_alias then table.insert(search_terms, iso_alias:lower()) end

  local function process_file(f, index, on_file_done)
    M.get_parsed_file_async(f, function(_, parsed)
      if not parsed then return on_file_done() end
      
      local basename = vim.fn.fnamemodify(f, ":t")
      local page_title = util.format_journal_date(basename, vault) or util.decode_filename(basename)
      local all_blocks = parser.flatten(parsed.blocks)

      for i, block in ipairs(all_blocks) do
        local content = block.content or ""
        local content_lower = content:lower()
        
        -- Sjekk om blokka inneholder noen av søketermene
        local is_match = false
        for _, term in ipairs(search_terms) do
          if content_lower:find(term, 1, true) then is_match = true; break end
        end

        if is_match then
          local display_text = content
          -- Hvis dette er en ren metadata-linje, "stjel" teksten fra forelderen
          if content:match("^SCHEDULED:") or content:match("^DEADLINE:") then
            if i > 1 then display_text = all_blocks[i-1].content .. "\n" .. content end
          end

          table.insert(results, {
            source_file = f,
            source_page = page_title,
            todo_state = block.todo or (i > 1 and all_blocks[i-1].todo),
            tags = block.tags or {},
            context_blocks = {{ text = display_text, indent = block.indent or 0, source_line = block.line_start or 1, is_match = true }}
          })
        end
      end
      on_file_done()
    end)
  end

  -- Ripgrep uten braketter for å unngå regex-feil
  local args = {"rg", "-l", "-i", "--fixed-strings"}
  for _, t in ipairs(search_terms) do table.insert(args, "-e"); table.insert(args, t) end
  table.insert(args, vault)

  vim.system(args, {text=true}, function(obj)
    vim.schedule(function()
      local matched = {}
      if obj.code == 0 and obj.stdout then
        for s in obj.stdout:gmatch("[^\r\n]+") do 
          if util.normalize(s) ~= norm_exclude then table.insert(matched, s) end
        end
      end
      M.process_file_list_batched(matched, process_file, function() 
        is_indexing = false
        on_complete(results) 
      end, on_progress)
    end)
  end)
end

-- ── Scheduled/Overdue-logikk (Flattet ut) ───────────────────────────
function M.find_scheduled_blocks(today_iso, on_complete)
  local vault = config.current.vault_path
  if not vault then return on_complete({ overdue = {}, upcoming = {} }) end
  
  local results = { overdue = {}, upcoming = {} }

  local function process_file(f, index, on_file_done)
    M.get_parsed_file_async(f, function(_, parsed)
      if not parsed then return on_file_done() end
      
      local basename = vim.fn.fnamemodify(f, ":t")
      local page_title = util.format_journal_date(basename, vault) or util.decode_filename(basename)
      local all_blocks = parser.flatten(parsed.blocks)
      
      for i, block in ipairs(all_blocks) do
        local content = block.content or ""
        
        -- Dato-ekstraksjon (Escaped hyphens for Lua)
        local logseq_date = content:match("SCHEDULED: <%s*(%d%d%d%d%-%d%d%-%d%d)") 
                         or content:match("DEADLINE: <%s*(%d%d%d%d%-%d%d%-%d%d)")
        local wiki_date = content:match("%[%[(%d%d%d%d%-%d%d%-%d%d)%]%]")
        local sched_date = logseq_date or wiki_date or block.scheduled or block.deadline
        
        -- Guard Clause: Hvis ingen dato, hopp over
        if not sched_date then goto next_block end

        -- Finn TODO-status (sjekk blokka eller blokka over)
        local todo = block.todo or (i > 1 and all_blocks[i-1].todo)
        
        -- Vi vil kun ha aktive oppgaver
        if todo and todo ~= "DONE" and todo ~= "CANCELLED" then
          local display_text = content
          if logseq_date and i > 1 then 
            display_text = all_blocks[i-1].content .. " " .. content 
          end

          local entry = {
            source_file = f,
            source_page = page_title,
            todo_state = todo,
            tags = block.tags or {},
            context_blocks = {{ text = display_text, indent = block.indent or 0, source_line = block.line_start or 1 }}
          }
          
          if sched_date <= today_iso then
            table.insert(results.overdue, entry)
          else
            table.insert(results.upcoming, entry)
          end
        end
        
        ::next_block::
      end
      on_file_done()
    end)
  end

  local date_regex = "[0-9]{4}-[0-9]{2}-[0-9]{2}"
  vim.system({"rg", "-l", "-e", "SCHEDULED:", "-e", "DEADLINE:", "-e", date_regex, vault}, {text=true}, function(obj)
    vim.schedule(function()
      local matched = {}
      if obj.code == 0 and obj.stdout then
        for s in obj.stdout:gmatch("[^\r\n]+") do table.insert(matched, s) end
      end
      M.process_file_list_batched(matched, process_file, function() on_complete(results) end)
    end)
  end)
end

return M