local M = {}

local function update_mtime(bufnr)
  local fp = vim.api.nvim_buf_get_name(bufnr)
  local st = vim.uv.fs_stat(fp)
  if st then vim.b[bufnr].logseq_mtime = st.mtime.sec end
end

function M.setup_buf(bufnr)
  local timer_id = nil
  local group = vim.api.nvim_create_augroup("logseq_autosave_" .. bufnr, { clear = true })

  update_mtime(bufnr)

  local function execute_save()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not vim.bo[bufnr].modified then return end

    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath == "" then return end

    local stat = vim.uv.fs_stat(filepath)
    local our_mtime = vim.b[bufnr].logseq_mtime

    if stat and our_mtime and stat.mtime.sec > our_mtime then
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        vim.api.nvim_buf_call(bufnr, function() vim.cmd("edit!") end)
        update_mtime(bufnr)
        vim.notify("[logseq.nvim] Reloaded (changed on disk)", vim.log.levels.INFO)
      end)
      return
    end

    vim.api.nvim_buf_call(bufnr, function()
      pcall(function() vim.cmd("silent! lockmarks update") end)
    end)
  end

  local function start_autosave_timer()
    if timer_id then vim.fn.timer_stop(timer_id) end
    timer_id = vim.fn.timer_start(10000, function()
      timer_id = nil
      execute_save()
    end)
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = start_autosave_timer,
  })

  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "FocusLost" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      if timer_id then
        vim.fn.timer_stop(timer_id)
        timer_id = nil
      end
      execute_save()
    end
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = bufnr,
    callback = function() update_mtime(bufnr) end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    callback = function()
      if timer_id then vim.fn.timer_stop(timer_id) end
    end
  })
end

return M