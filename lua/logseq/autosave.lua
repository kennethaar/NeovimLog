local M = {}

local function update_mtime(bufnr)
  local fp = vim.api.nvim_buf_get_name(bufnr)
  local st = vim.uv.fs_stat(fp)
  if st then vim.b[bufnr].logseq_mtime = st.mtime.sec end
end

function M.setup_buf(bufnr)
  local timer_id = nil

  -- Record the file's mtime at buffer load so we can detect external changes.
  update_mtime(bufnr)

  -- Cache dedup at setup time; graceful if the module is unavailable.
  local ok_dedup, dedup = pcall(require, "logseq.dedup")
  if not ok_dedup then dedup = nil end

  -- Merge external changes into the buffer right before writing.
  -- Fires for BOTH manual :w and the autosave :write call, so nothing slips through.
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = bufnr,
    callback = function()
      local filepath = vim.api.nvim_buf_get_name(bufnr)
      if filepath == "" then return end

      local stat = vim.uv.fs_stat(filepath)
      local our_mtime = vim.b[bufnr].logseq_mtime
      if not (stat and our_mtime and stat.mtime.sec > our_mtime) then return end

      -- File was changed by another session.  Read disk content directly —
      -- no edit! needed, which would wipe undo history and fire extra autocmds.
      local f = io.open(filepath, "r")
      if not f then return end
      local disk_content = f:read("*a")
      f:close()

      if not dedup then
        -- dedup unavailable: warn and let the write proceed as-is rather than
        -- silently losing one side.
        vim.notify(
          "[logseq.nvim] External change detected but dedup module unavailable — save aborted. Fix logseq.dedup and retry.",
          vim.log.levels.WARN
        )
        -- Returning from BufWritePre does not abort the write; use a Lua error to
        -- surface the problem without corrupting anything.
        error("logseq.autosave: aborting write — dedup unavailable")
        return
      end

      local disk_lines = vim.split(disk_content, "\n", { plain = true })
      -- vim.split("a\nb\n", "\n") produces {"a","b",""} — drop trailing empty entry
      if disk_lines[#disk_lines] == "" then table.remove(disk_lines) end

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      -- Disk-first so the other session's content is the base; our new lines follow.
      vim.list_extend(disk_lines, buf_lines)
      local merged = dedup.dedup_lines(disk_lines)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, merged)

      -- Advance our mtime snapshot to the disk's current value so BufWritePost
      -- (which also calls update_mtime) doesn't see a stale delta.
      vim.b[bufnr].logseq_mtime = stat.mtime.sec

      vim.notify("[logseq.nvim] Merged local edits with external changes", vim.log.levels.INFO)
    end,
  })

  local function execute_save()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not vim.bo[bufnr].modified then return end
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath == "" then return end
    -- BufWritePre (above) handles any external-change merging automatically.
    vim.api.nvim_buf_call(bufnr, function()
      pcall(function() vim.cmd("write") end)
    end)
  end

  -- Debounced 10-second autosave on typing.
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

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    callback = start_autosave_timer,
  })

  -- Immediate save when leaving insert mode or the buffer, so :q never hits E37.
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "FocusLost" }, {
    buffer = bufnr,
    callback = function()
      if timer_id then
        vim.fn.timer_stop(timer_id)
        timer_id = nil
      end
      execute_save()
    end,
  })

  -- Keep stored mtime in sync after any write (autosave or manual :w).
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    callback = function() update_mtime(bufnr) end,
  })

  -- Clean up the timer when the buffer is closed.
  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = bufnr,
    callback = function()
      if timer_id then
        vim.fn.timer_stop(timer_id)
        timer_id = nil
      end
    end,
  })
end

return M
