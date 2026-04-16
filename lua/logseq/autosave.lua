local M = {}

--- Get precise mtime (seconds + nanoseconds)
local function get_precise_mtime(bufnr)
  local fp = vim.api.nvim_buf_get_name(bufnr)
  local st = vim.uv.fs_stat(fp)
  if st then 
    return { sec = st.mtime.sec, nsec = st.mtime.nsec }
  end
  return nil
end

function M.setup_buf(bufnr)
  local timer = vim.uv.new_timer()
  vim.b[bufnr].logseq_mtime = get_precise_mtime(bufnr)

  local function execute_save()
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.bo[bufnr].modified then return end
    
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath == "" then return end

    local stat = vim.uv.fs_stat(filepath)
    local last_mtime = vim.b[bufnr].logseq_mtime

    -- Check for external changes (Syncthing)
    if stat and last_mtime then
      local disk_newer = (stat.mtime.sec > last_mtime.sec) or 
                         (stat.mtime.sec == last_mtime.sec and stat.mtime.nsec > last_mtime.nsec)
      
      if disk_newer then
        -- SAFETY: Do not call edit! if buffer is modified. 
        -- This prevents discarding your current unsaved session.
        vim.schedule(function()
          vim.notify("[logseq.nvim] External change detected. Save aborted. Use :edit! to discard or :diffupdate to merge.", vim.log.levels.WARN)
        end)
        return
      end
    end

    -- Perform the write
    vim.api.nvim_buf_call(bufnr, function()
      pcall(function() vim.cmd("silent! write") end)
    end)
  end

  local function start_timer()
    timer:stop()
    timer:start(10000, 0, vim.schedule_wrap(execute_save))
  end

  local group = vim.api.nvim_create_augroup("LogseqAutosave_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group, buffer = bufnr, callback = start_timer,
  })

  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "FocusLost" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      timer:stop()
      execute_save()
    end
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = bufnr,
    callback = function() vim.b[bufnr].logseq_mtime = get_precise_mtime(bufnr) end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    callback = function()
      if not timer:is_closing() then timer:close() end
    end
  })
end

return M