local M = {}

--- Store both sec and nsec so two saves within the same wall-clock second
--- are still distinguishable on filesystems that expose sub-second precision.
local function update_mtime(bufnr)
  local fp = vim.api.nvim_buf_get_name(bufnr)
  local st = vim.uv.fs_stat(fp)
  if st then
    vim.b[bufnr].logseq_mtime     = st.mtime.sec
    vim.b[bufnr].logseq_mtime_nsec = st.mtime.nsec or 0
  end
end

--- True when the on-disk file is strictly newer than our last snapshot.
local function disk_is_newer(stat, bufnr)
  local our_sec  = vim.b[bufnr].logseq_mtime
  local our_nsec = vim.b[bufnr].logseq_mtime_nsec or 0
  if not our_sec then return false end
  local s, n = stat.mtime.sec, stat.mtime.nsec or 0
  return s > our_sec or (s == our_sec and n > our_nsec)
end

--- True when the on-disk mtime exactly matches our last recorded write
--- (i.e. this is a change we made ourselves, not an external session).
local function is_own_write(stat, bufnr)
  return stat.mtime.sec == vim.b[bufnr].logseq_mtime
     and (stat.mtime.nsec or 0) == (vim.b[bufnr].logseq_mtime_nsec or 0)
end

--- Atomic write: temp file + rename so a crash can't leave a half-written file.
--- The PID is embedded in the temp name so two sessions don't clobber each other's
--- in-flight write.
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

function M.setup_buf(bufnr)
  local timer_id = nil

  update_mtime(bufnr)

  local ok_dedup, dedup = pcall(require, "logseq.dedup")
  if not ok_dedup then dedup = nil end

  local filepath = vim.api.nvim_buf_get_name(bufnr)

  -- ── FileChangedShell ───────────────────────────────────────────────
  --
  -- BufWriteCmd bypasses Neovim's normal buf_write() path, so Neovim's
  -- internal b_mtime record is NEVER updated after our writes.  Every
  -- subsequent checktime() (FocusGained / CursorHold) therefore fires
  -- FileChangedShell with b_mtime < disk mtime — even for saves we just
  -- made ourselves.  Without this handler that produces a false-positive
  -- "Reloaded (changed externally)" notification on every focus switch.
  --
  -- Strategy:
  --   own write        → ignore (content correct, preserve undo history)
  --   external change, modified buffer  → ignore (BufWriteCmd merges on next save)
  --   external change, clean buffer     → reload  (pick up the new content)
  --
  -- The "ignore for own write" path leaves b_mtime stale, so FileChangedShell
  -- fires on every checktime — but the callback is a single fs_stat + compare,
  -- cheap enough not to matter.  The loop stops naturally when an external
  -- change causes a "reload" and b_mtime is updated.
  vim.api.nvim_create_autocmd("FileChangedShell", {
    pattern = filepath,
    callback = function()
      if vim.api.nvim_get_current_buf() ~= bufnr then return end
      local stat = vim.uv.fs_stat(filepath)
      if not stat then vim.v.fcs_choice = "ignore"; return end

      if is_own_write(stat, bufnr) then
        -- Our own BufWriteCmd write — suppress the reload to keep undo history.
        vim.v.fcs_choice = "ignore"
        return
      end

      if vim.bo[bufnr].modified then
        -- Unsaved edits exist — don't clobber them; BufWriteCmd will merge.
        vim.v.fcs_choice = "ignore"
      else
        -- Clean buffer + genuine external change — reload to get the new content.
        -- FileChangedShellPost will fire afterwards and update logseq_mtime.
        vim.v.fcs_choice = "reload"
      end
    end,
  })

  -- ── BufWriteCmd ────────────────────────────────────────────────────
  --
  -- Completely replaces Neovim's write path for this file.
  -- Registered by file-path pattern (not buffer number) because buf_write()
  -- in the C layer matches BufWriteCmd against the filename.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern = filepath,
    callback = function()
      if vim.api.nvim_get_current_buf() ~= bufnr then return end

      local stat = vim.uv.fs_stat(filepath)
      local final_lines

      if stat and disk_is_newer(stat, bufnr) then
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
            -- vim.split("a\nb\n") gives {"a","b",""} — drop trailing empty
            if disk_lines[#disk_lines] == "" then table.remove(disk_lines) end
            local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            -- Disk first (other session's base); our additions append after.
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
        -- BufWriteCmd suppresses BufWritePost; fire it so subscribers
        -- (mtime update, date-file auto-move in init.lua, etc.) still run.
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
    -- :write triggers BufWriteCmd above.
    vim.api.nvim_buf_call(bufnr, function()
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

  -- Immediate save on leaving insert mode or buffer, so :q never hits E37.
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "FocusLost" }, {
    buffer = bufnr,
    callback = function()
      if timer_id then vim.fn.timer_stop(timer_id); timer_id = nil end
      execute_save()
    end,
  })

  -- Keep logseq_mtime current after every write (own or external reload).
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    callback = function() update_mtime(bufnr) end,
  })

  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = bufnr,
    callback = function()
      if timer_id then vim.fn.timer_stop(timer_id); timer_id = nil end
    end,
  })
end

return M
