local M = {}

-- ── libuv helpers ──────────────────────────────────────────────────────

local function atomic_write(filepath, content)
  local uv = vim.uv
  local tmp = filepath .. ".nvim_save_" .. vim.fn.getpid() .. "_tmp"
  local fd = uv.fs_open(tmp, "w", 438)
  if not fd then return false end
  local ok = pcall(uv.fs_write, fd, content, 0)
  uv.fs_close(fd)
  if not ok then pcall(uv.fs_unlink, tmp); return false end
  if uv.fs_rename(tmp, filepath) then return true end
  -- Cross-device rename can fail; fall back to a direct write.
  pcall(uv.fs_unlink, tmp)
  local fd2 = uv.fs_open(filepath, "w", 438)
  if not fd2 then return false end
  local ok2 = pcall(uv.fs_write, fd2, content, 0)
  uv.fs_close(fd2)
  return ok2
end

local function read_file_sync(filepath)
  local uv = vim.uv
  local stat = uv.fs_stat(filepath)
  if not stat then return nil, nil end
  local fd = uv.fs_open(filepath, "r", 438)
  if not fd then return nil, nil end
  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return content, stat
end

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

-- ── Merge disk + buffer via dedup ──────────────────────────────────────

-- Called inside vim.schedule so all buffer APIs are safe to use.
local function merge_into_buffer_async(bufnr, filepath)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local content, stat = read_file_sync(filepath)
  if not content or not stat then return end

  local disk = vim.split(content, "\n", { plain = true })
  if disk[#disk] == "" then table.remove(disk) end
  local buf = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local combined = {}
  vim.list_extend(combined, disk)
  vim.list_extend(combined, buf)
  local merged = require("logseq.dedup").dedup_lines(combined)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, merged)
  vim.b[bufnr].logseq_mtime      = stat.mtime.sec
  vim.b[bufnr].logseq_mtime_nsec = stat.mtime.nsec or 0
  vim.notify(
    "[logseq.nvim] Merged external changes into '" .. vim.fn.fnamemodify(filepath, ":t") .. "'",
    vim.log.levels.WARN)
end

-- Synchronous variant used inside BufWriteCmd where we must settle before writing.
local function merge_into_buffer_sync(bufnr, filepath)
  local content, stat = read_file_sync(filepath)
  if not content or not stat then return end
  local disk = vim.split(content, "\n", { plain = true })
  if disk[#disk] == "" then table.remove(disk) end
  local buf = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local combined = {}
  vim.list_extend(combined, disk)
  vim.list_extend(combined, buf)
  local merged = require("logseq.dedup").dedup_lines(combined)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, merged)
  vim.b[bufnr].logseq_mtime      = stat.mtime.sec
  vim.b[bufnr].logseq_mtime_nsec = stat.mtime.nsec or 0
end

-- ── setup_buf ──────────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  local group = vim.api.nvim_create_augroup("logseq_autosave_" .. bufnr, { clear = true })
  local timer = vim.uv.new_timer()

  update_mtime(bufnr)

  -- FileChangedShell: decide ignore / reload / merge when disk changes on us.
  vim.api.nvim_create_autocmd("FileChangedShell", {
    group = group, buffer = bufnr,
    callback = function()
      local stat = vim.uv.fs_stat(filepath)
      if not stat or is_own_write(stat, bufnr) then
        vim.v.fcs_choice = "ignore"
        return
      end
      if not vim.bo[bufnr].modified then
        vim.v.fcs_choice = "reload"
        return
      end
      vim.v.fcs_choice = "ignore"
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          merge_into_buffer_async(bufnr, filepath)
        end
      end)
    end,
  })

  -- BufWriteCmd: atomic libuv write (+ merge first if disk diverged).
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group, buffer = bufnr,
    callback = function()
      if vim.api.nvim_get_current_buf() ~= bufnr then return end

      local stat = vim.uv.fs_stat(filepath)
      if stat and not is_own_write(stat, bufnr) then
        merge_into_buffer_sync(bufnr, filepath)
      end

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local content = table.concat(lines, "\n")
      if content ~= "" then content = content .. "\n" end

      if atomic_write(filepath, content) then
        vim.bo[bufnr].modified = false
        vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
      else
        vim.notify("[logseq.nvim] Write failed: " .. filepath, vim.log.levels.ERROR)
      end
    end,
  })

  -- Debounced autosave timer driven by text-change events.
  local function schedule_save()
    timer:stop()
    timer:start(10000, 0, vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified then
        pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd("silent! write") end)
      end
    end))
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group, buffer = bufnr, callback = schedule_save,
  })

  -- Immediate save on context-leaving events.
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "FocusLost", "CursorHold", "CursorHoldI" }, {
    group = group, buffer = bufnr,
    callback = function()
      timer:stop()
      if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified then
        pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd("silent! write") end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group, buffer = bufnr, callback = function() update_mtime(bufnr) end,
  })

  -- Cross-session sync + Syncthing conflict detection on cursor activity.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter" }, {
    group = group, buffer = bufnr,
    callback = function()
      -- Skip checktime while the buffer has unsaved changes. Our atomic_write
      -- updates the file mtime but Neovim's internal b_mtime_read stays at the
      -- original open-time value, so checktime would always see a mismatch and
      -- show W12. External changes are handled at write time by BufWriteCmd.
      if vim.bo[bufnr].modified then return end
      local now = vim.uv.now()
      if vim.b[bufnr].last_checktime and (now - vim.b[bufnr].last_checktime <= 2000) then return end
      vim.b[bufnr].last_checktime = now
      pcall(vim.cmd, "checktime " .. vim.fn.fnameescape(filepath))

      if not _G.logseq_last_conflict_scan or (now - _G.logseq_last_conflict_scan > 15000) then
        _G.logseq_last_conflict_scan = now
        vim.defer_fn(function()
          pcall(function()
            local dir  = vim.fn.fnamemodify(filepath, ":h")
            local tail = vim.fn.fnamemodify(filepath, ":t:r")
            local ext  = vim.fn.fnamemodify(filepath, ":e")
            local pattern = string.format("%s/%s.sync-conflict-*.%s", dir, tail, ext)
            local conflicts = vim.fn.glob(pattern, false, true)
            if type(conflicts) == "table" and #conflicts > 0 then
              local vault = require("logseq.config").current.vault_path
              require("logseq.sync_conflicts").auto_resolve_one(conflicts[1], filepath, vault)
              pcall(vim.cmd, "checktime " .. vim.fn.fnameescape(filepath))
            end
          end)
        end, 500)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group, buffer = bufnr,
    callback = function()
      if timer then
        timer:stop()
        if not timer:is_closing() then timer:close() end
      end
    end,
  })
end

return M
