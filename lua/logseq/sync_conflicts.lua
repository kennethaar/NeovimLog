local M = {}
local dedup = require("logseq.dedup")
local CONFLICT_SUFFIX = "%.sync%-conflict%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%w+"

function M.launch_diff_tool(original, conflict)
  vim.schedule(function()
    vim.cmd("tabnew")
    local buf_orig = vim.fn.bufadd(original)
    local buf_conf = vim.fn.bufadd(conflict)
    vim.api.nvim_set_current_buf(buf_orig)
    vim.cmd("vsplit")
    local wins = vim.api.nvim_tabpage_list_wins(0)
    vim.api.nvim_win_set_buf(wins[1], buf_conf)
    vim.cmd("windo diffthis")
    vim.cmd("redraw") 

    -- FIKSET: Laget en fornuftig avslutning på hjelpetekst og autocmd
    vim.notify("Conflict detected: Left = Conflict, Right = Original", vim.log.levels.INFO)
    
    vim.api.nvim_create_autocmd("BufWinLeave", {
      buffer = buf_conf,
      once = true,
      callback = function()
        vim.schedule(function()
          print("Conflict window closed. Run resolve_all again if needed.")
        end)
      end
    })
    
    vim.api.nvim_set_current_win(wins[2])
  end)
end

function M.auto_resolve_one(conflict_path, original_path, vault, on_done)
  dedup.read_file_async(original_path, function(orig)
    dedup.read_file_async(conflict_path, function(conf)
      if not orig then
        -- Hvis originalen er borte, adopterer vi bare konflikt-filen
        vim.uv.fs_rename(conflict_path, original_path, function() on_done("adopted") end)
        return
      end
      if not conf or orig == conf then
        -- Hvis de er identiske, slett konflikten
        if conf then vim.uv.fs_unlink(conflict_path) end
        return on_done("identical")
      end

      local is_ff = conf:find(orig, 1, true) or orig:find(conf, 1, true)
      if is_ff then
        dedup.backup_file_async(original_path, vault, orig)
        local lines = vim.split(orig.. "\n".. conf, "\n", { plain = true })
        local cleaned = dedup.dedup_lines(lines)
        dedup.safe_write_async(original_path, table.concat(cleaned, "\n").. "\n", function(success)
          if success then
            vim.uv.fs_unlink(conflict_path)
            on_done("merged")
          else
            on_done("manual")
          end
        end)
      else
        on_done("manual")
      end
    end)
  end)
end

function M.scan_conflicts_async(vault, callback)
  local uv = vim.uv or vim.loop
  local results = {}
  local dirs = { vault.. "/pages", vault.. "/journals" }
  local pending = #dirs

  local function check_done()
    pending = pending - 1
    if pending == 0 then callback(results) end
  end

  for _, dir in ipairs(dirs) do
    uv.fs_opendir(dir, function(err, fd)
      if err or not fd then return check_done() end
      local function read_entries()
        uv.fs_readdir(fd, function(err_read, entries)
          if err_read or not entries then
            uv.fs_closedir(fd)
            return check_done()
          end
          for _, entry in ipairs(entries) do
            if entry.name:match(CONFLICT_SUFFIX) then
              local original_name = entry.name:gsub(CONFLICT_SUFFIX, "")
              local original = dir.. "/".. original_name
              table.insert(results, { conflict = dir.. "/".. entry.name, original = original })
            end
          end
          read_entries() 
        end)
      end
      read_entries()
    end, 1000) 
  end
end

function M.resolve_all(vault)
  if not vault or vault == "" then return end
  
  M.scan_conflicts_async(vault, function(conflicts)
    if #conflicts == 0 then return end
    
    local manual_found = false
    local function next_conflict(index)
      if index > #conflicts then
        if manual_found then
          vim.schedule(function() vim.notify("Manual resolution required for some files.", vim.log.levels.WARN) end)
        end
        return
      end
      
      local c = conflicts[index]
      M.auto_resolve_one(c.conflict, c.original, vault, function(outcome)
        if outcome == "manual" and not manual_found then
          manual_found = true
          M.launch_diff_tool(c.original, c.conflict)
        end
        next_conflict(index + 1)
      end)
    end
    
    next_conflict(1)
  end)
end

return M