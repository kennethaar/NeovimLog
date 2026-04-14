local M = {}

local function update_mtime(bufnr)
  local fp = vim.api.nvim_buf_get_name(bufnr)
  local st = vim.uv.fs_stat(fp)
  if st then
    vim.b[bufnr].logseq_mtime      = st.mtime.sec
    vim.b[bufnr].logseq_mtime_nsec = st.mtime.nsec or 0
  end
end

local function is_own_write(stat, bufnr)
  return stat.mtime.sec == vim.b[bufnr].logseq_mtime
     and (stat.mtime.nsec or 0) == (vim.b[bufnr].logseq_mtime_nsec or 0)
end

local function atomic_write(filepath, lines)
  local tmp = filepath .. ".nvim_save_" .. vim.fn.getpid() .. "_tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  local ok = pcall(function() f:write(table.concat(lines, "\n") .. "\n") end)
  f:close()
  if not ok then os.remove(tmp); return false end
  if not vim.uv.fs_rename(tmp, filepath) then os.remove(tmp); return false end
  return true
end

local function do_merge(disk_lines, buf_lines)
  local ok_d, d = pcall(require, "logseq.dedup")
  if ok_d and d then
    local combined = {}
    vim.list_extend(combined, disk_lines)
    vim.list_extend(combined, buf_lines)
    return (d.dedup_lines(combined))
  end
  local seen, result = {}, {}
  for _, l in ipairs(disk_lines) do
    if not seen[l] then seen[l] = true; result[#result + 1] = l end
  end
  for _, l in ipairs(buf_lines) do
    if not seen[l] then seen[l] = true; result[#result + 1] = l end
  end
  return result
end

local function merge_into_buffer(bufnr, filepath)
  local stat = vim.uv.fs_stat(filepath)
  if not stat then return end
  local f = io.open(filepath, "r")
  if not f then return end
  local content = f:read("*a"); f:close()
  local disk_lines = vim.split(content, "\n", { plain = true })
  if disk_lines[#disk_lines] == "" then table.remove(disk_lines) end
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, do_merge(disk_lines, buf_lines))
  vim.b[bufnr].logseq_mtime      = stat.mtime.sec
  vim.b[bufnr].logseq_mtime_nsec = stat.mtime.nsec or 0
  vim.notify(
    "[logseq.nvim] Merged external changes into '"
      .. vim.fn.fnamemodify(filepath, ":t") .. "'",
    vim.log.levels.WARN
  )
end

function M.setup_buf(bufnr)
  local timer_id = nil

  update_mtime(bufnr)

  local filepath = vim.api.nvim_buf_get_name(bufnr)

  -- ── FileChangedShell ───────────────────────────────────────────────
  vim.api.nvim_create_autocmd("FileChangedShell", {
    pattern = filepath,
    callback = function()
      local stat = vim.uv.fs_stat(filepath)
      if not stat then vim.v.fcs_choice = "ignore"; return end
      if is_own_write(stat, bufnr) then vim.v.fcs_choice = "ignore"; return end

      if not vim.bo[bufnr].modified then
        vim.v.fcs_choice = "reload"
        return
      end

      local in_insert = vim.api.nvim_get_current_buf() == bufnr
                        and vim.api.nvim_get_mode().mode:match("^i")

      if in_insert then
        vim.v.fcs_choice = "ignore"
        -- Use synchronous merge instead of vim.schedule so we don't race against saves
        if vim.api.nvim_buf_is_valid(bufnr) then
          merge_into_buffer(bufnr, filepath)
        end
        return
      end

      local saved = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      vim.v.fcs_choice = "reload"
      
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        local disk = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (do_merge(disk, saved)))
        vim.bo[bufnr].modified = true
        vim.notify(
          "[logseq.nvim] Merged external changes into '"
            .. vim.fn.fnamemodify(filepath, ":t") .. "'",
          vim.log.levels.WARN
        )
      end)
    end,
  })

  -- ── BufWriteCmd ────────────────────────────────────────────────────
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern = filepath,
    callback = function()
      if vim.api.nvim_get_current_buf() ~= bufnr then return end

      local stat = vim.uv.fs_stat(filepath)
      if stat and not is_own_write(stat, bufnr) then
        merge_into_buffer(bufnr, filepath)
      end

      local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      if atomic_write(filepath, final_lines) then
        vim.bo[bufnr].modified = false
        vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
      else
        vim.notify("[logseq.nvim] Write failed: " .. filepath, vim.log.levels.ERROR)
      end
    end,
  })

  -- ── Autosave timer ─────────────────────────────────────────────────
  local function execute_save()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not vim.bo[bufnr].modified then return end
    if filepath == "" then return end
    
    -- CRITICAL FIX 1: Look at the disk right before saving.
    -- If Syncthing changed the file a millisecond ago, FileChangedShell will catch it here.
    pcall(vim.cmd, "checktime " .. vim.fn.fnameescape(filepath))

    vim.api.nvim_buf_call(bufnr, function()
      -- CRITICAL FIX 2: Drop the "!" bang. Let Neovim respect its internal locks.
      pcall(function() vim.cmd("write") end)
    end)
  end

  local function start_autosave_timer()
    if timer_id then vim.fn.timer_stop(timer_id); timer_id = nil end
    timer_id = vim.fn.timer_start(10000, function()
      timer_id = nil
      execute_save()
    end)
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    callback = start_autosave_timer,
  })

  vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
    buffer = bufnr,
    callback = function()
      if timer_id then vim.fn.timer_stop(timer_id); timer_id = nil end
      execute_save()
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "FocusLost" }, {
    buffer = bufnr,
    callback = function()
      if timer_id then vim.fn.timer_stop(timer_id); timer_id = nil end
      execute_save()
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    callback = function() update_mtime(bufnr) end,
  })

  -- ── Event-Driven Cross-Session Sync ────────────────────────────────
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter" }, {
    buffer = bufnr,
    callback = function()
      local now = vim.uv.now()
      if not vim.b[bufnr].last_checktime or (now - vim.b[bufnr].last_checktime > 2000) then
        vim.b[bufnr].last_checktime = now
        pcall(vim.cmd, "checktime " .. vim.fn.fnameescape(filepath))
        
        -- PERFORMANCE FIX: Do not scan the entire vault while typing.
        -- Only check if a conflict exists for the exact file we are looking at.
        if not _G.logseq_last_conflict_scan or (now - _G.logseq_last_conflict_scan > 15000) then
          _G.logseq_last_conflict_scan = now
          vim.defer_fn(function()
            pcall(function()
              local dir = vim.fn.fnamemodify(filepath, ":h")
              local tail = vim.fn.fnamemodify(filepath, ":t:r")
              local ext = vim.fn.fnamemodify(filepath, ":e")
              local pattern = string.format("%s/%s.sync-conflict-*.%s", dir, tail, ext)
              
              local conflicts = vim.fn.glob(pattern, false, true)
              if #conflicts > 0 then
                local vault = require("logseq.config").current.vault_path
                require("logseq.sync_conflicts").auto_resolve_one(conflicts[1], filepath, vault)
                pcall(vim.cmd, "checktime " .. vim.fn.fnameescape(filepath))
              end
            end)
          end, 500)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = bufnr,
    callback = function()
      if timer_id then vim.fn.timer_stop(timer_id); timer_id = nil end
    end,
  })
end

return M