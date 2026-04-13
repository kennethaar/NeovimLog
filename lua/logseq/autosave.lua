local M = {}

local function update_mtime(bufnr)
  local fp = vim.api.nvim_buf_get_name(bufnr)
  local st = vim.uv.fs_stat(fp)
  if st then vim.b[bufnr].logseq_mtime = st.mtime.sec end
end

function M.setup_buf(bufnr)
  local timer_id = nil

  -- Record the file's mtime at buffer load so we can detect external changes
  update_mtime(bufnr)

  local function execute_save()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not vim.bo[bufnr].modified then return end

    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath == "" then return end

    local stat = vim.uv.fs_stat(filepath)
    local our_mtime = vim.b[bufnr].logseq_mtime

    -- File changed externally (Syncthing) — reload instead of overwriting
    if stat and our_mtime and stat.mtime.sec > our_mtime then
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        vim.api.nvim_buf_call(bufnr, function() vim.cmd("edit!") end)
        update_mtime(bufnr)
        vim.notify("[logseq.nvim] Reloaded (changed on disk)", vim.log.levels.INFO)
      end)
      return
    end

    -- Safe to write
    vim.api.nvim_buf_call(bufnr, function()
      pcall(function() vim.cmd("write") end)
    end)
    update_mtime(bufnr)
  end

  -- The debounced timer
  local function start_autosave_timer()
    if timer_id then
      vim.fn.timer_stop(timer_id)
      timer_id = nil
    end

    timer_id = vim.fn.timer_start(10000, function()
      timer_id = nil
      execute_save()
    end)
  end

  -- Trigger the 10-second countdown when typing
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    callback = start_autosave_timer,
  })

  -- Force an IMMEDIATE save if you leave insert mode or leave the buffer
  -- This prevents the E37 error if you try to :q before the 10 seconds are up!
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "FocusLost" }, {
    buffer = bufnr,
    callback = function()
      if timer_id then
        vim.fn.timer_stop(timer_id)
        timer_id = nil
      end
      execute_save()
    end
  })

  -- Keep stored mtime in sync after any manual :w
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    callback = function() update_mtime(bufnr) end,
  })

  -- Clean up timer when closing the buffer entirely
  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = bufnr,
    callback = function()
      if timer_id then
        vim.fn.timer_stop(timer_id)
        timer_id = nil
      end
    end
  })
end

return M
