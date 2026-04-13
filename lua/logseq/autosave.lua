local M = {}

local function update_mtime(bufnr)
  local fp = vim.api.nvim_buf_get_name(bufnr)
  local st = vim.uv.fs_stat(fp)
  if st then vim.b[bufnr].logseq_mtime = st.mtime.sec end
end

--- Atomic write: write to a temp file then rename, so a crash mid-write
--- cannot leave the target file half-written.
local function atomic_write(filepath, lines)
  local tmp = filepath .. ".nvim_autosave_tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  local ok = pcall(function() f:write(table.concat(lines, "\n") .. "\n") end)
  f:close()
  if not ok then os.remove(tmp); return false end
  if not vim.uv.fs_rename(tmp, filepath) then os.remove(tmp); return false end
  return true
end

function M.setup_buf(bufnr)
  local timer_id = nil

  -- Snapshot the file's mtime when the buffer is loaded.
  update_mtime(bufnr)

  -- Cache dedup at setup time with graceful fallback.
  local ok_dedup, dedup = pcall(require, "logseq.dedup")
  if not ok_dedup then dedup = nil end

  local filepath = vim.api.nvim_buf_get_name(bufnr)

  -- BufWriteCmd completely replaces Neovim's write path for this file, so
  -- the C-level mtime check (and its "file changed since reading" prompt)
  -- never runs.
  --
  -- IMPORTANT: register by file-path pattern, not `buffer = bufnr`.
  -- buf_write() in the C layer matches BufWriteCmd against the filename,
  -- not the buffer number.  A buffer-local registration is silently skipped
  -- by the pattern matcher for manual :w, which is why the prompt kept
  -- appearing even after adding BufWriteCmd.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern = filepath,
    callback = function()
      -- Guard: only handle writes that belong to this specific buffer.
      if vim.api.nvim_get_current_buf() ~= bufnr then return end

      local stat      = vim.uv.fs_stat(filepath)
      local our_mtime = vim.b[bufnr].logseq_mtime
      local final_lines

      if stat and our_mtime and stat.mtime.sec > our_mtime then
        -- Another session wrote the file while we were editing.
        if not dedup then
          vim.notify(
            "[logseq.nvim] External change detected — dedup unavailable, writing local version.",
            vim.log.levels.WARN
          )
          final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        else
          local f = io.open(filepath, "r")
          if f then
            local disk_content = f:read("*a")
            f:close()
            local disk_lines = vim.split(disk_content, "\n", { plain = true })
            -- vim.split on "a\nb\n" gives {"a","b",""} — drop trailing empty
            if disk_lines[#disk_lines] == "" then table.remove(disk_lines) end
            local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            -- Disk first; our new lines append at the end.
            vim.list_extend(disk_lines, buf_lines)
            final_lines = dedup.dedup_lines(disk_lines)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, final_lines)
            vim.notify("[logseq.nvim] Merged local edits with external changes", vim.log.levels.INFO)
          else
            final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          end
        end
      else
        final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      end

      if atomic_write(filepath, final_lines) then
        -- BufWriteCmd requires us to clear 'modified' ourselves.
        vim.bo[bufnr].modified = false
        -- BufWriteCmd suppresses BufWritePost; fire it so other subscribers
        -- (mtime update, date-file auto-move in init.lua, etc.) still run.
        vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
      else
        vim.notify("[logseq.nvim] Write failed: " .. filepath, vim.log.levels.ERROR)
      end
    end,
  })

  local function execute_save()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not vim.bo[bufnr].modified then return end
    if filepath == "" then return end
    -- :write triggers BufWriteCmd above, which handles conflict detection
    -- and the actual disk write.
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

  -- Immediate save on leaving insert mode or buffer, so :q never hits E37.
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

  -- Keep the mtime snapshot current after every write.
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    callback = function() update_mtime(bufnr) end,
  })

  -- Clean up the debounce timer when the buffer is closed.
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
