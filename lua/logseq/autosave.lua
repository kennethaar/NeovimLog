local M = {}

--- Store both sec and nsec so two saves within the same wall-clock second
--- are still distinguishable on filesystems that expose sub-second precision.
local function update_mtime(bufnr)
  local fp = vim.api.nvim_buf_get_name(bufnr)
  local st = vim.uv.fs_stat(fp)
  if st then
    vim.b[bufnr].logseq_mtime      = st.mtime.sec
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

--- Merge two line lists: disk lines first (peer's content), then buf lines
--- (local edits).  Uses block-tree-aware dedup when available; falls back to
--- a plain set-union so no line from either side is ever silently dropped.
local function do_merge(disk_lines, buf_lines)
  local ok_d, d = pcall(require, "logseq.dedup")
  if ok_d and d then
    local combined = {}
    vim.list_extend(combined, disk_lines)
    vim.list_extend(combined, buf_lines)
    return (d.dedup_lines(combined))
  end
  -- Fallback: set-union preserves every line from both sides.
  local seen, result = {}, {}
  for _, l in ipairs(disk_lines) do
    if not seen[l] then seen[l] = true; result[#result + 1] = l end
  end
  for _, l in ipairs(buf_lines) do
    if not seen[l] then seen[l] = true; result[#result + 1] = l end
  end
  return result
end

--- Read disk → merge → write back to the in-memory buffer without reloading.
--- Safe to call when the buffer is active (including during insert mode).
--- Updates logseq_mtime so the same external change isn't re-merged next time.
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
    "[logseq.nvim] Peer changes merged into '"
      .. vim.fn.fnamemodify(filepath, ":t") .. "' — save when ready",
    vim.log.levels.WARN
  )
end

function M.setup_buf(bufnr)
  local timer_id = nil

  update_mtime(bufnr)

  local filepath = vim.api.nvim_buf_get_name(bufnr)

  -- ── FileChangedShell ───────────────────────────────────────────────
  --
  -- CRITICAL: the callback must ALWAYS set vim.v.fcs_choice before returning.
  -- If it returns without setting it, Neovim falls back to showing the blocking
  -- "WARNING: The file has been changed since reading it!!! Do you really want
  -- to write to it (y/n)?" dialog.  That is the prompt the user reported.
  --
  -- Root cause of the W12 dialog:
  --   Neovim tracks a per-buffer b_mtime.  BufWriteCmd bypasses the normal
  --   write path so b_mtime is never updated by our saves.  When we use
  --   fcs_choice="ignore" on a modified buffer, b_mtime stays stale.  The
  --   next :write (or :write!) call compares b_mtime against disk and fires W12.
  --
  -- Fix for normal mode: use fcs_choice="reload".  Neovim reloads the file
  --   from disk, which updates b_mtime, eliminating future W12 prompts.
  --   We capture the user's edits BEFORE the reload and merge them back in
  --   via vim.schedule once the reload completes.
  --
  -- Fix for insert mode: can't reload mid-typing (would disrupt the user).
  --   Instead keep fcs_choice="ignore" and merge in-place.  execute_save uses
  --   :write! (bang) to bypass the W12 check when it fires later.
  vim.api.nvim_create_autocmd("FileChangedShell", {
    pattern = filepath,
    callback = function()
      local stat = vim.uv.fs_stat(filepath)
      if not stat then vim.v.fcs_choice = "ignore"; return end

      if is_own_write(stat, bufnr) then
        -- Our own BufWriteCmd write — suppress reload to keep undo history.
        vim.v.fcs_choice = "ignore"
        return
      end

      if vim.bo[bufnr].modified then
        -- Buffer has unsaved edits.  Strategy depends on whether the user
        -- is actively typing (insert mode) in THIS buffer right now.
        local in_insert = vim.api.nvim_get_current_buf() == bufnr
                          and vim.api.nvim_get_mode().mode:match("^i")

        if in_insert then
          -- Merge in-place without reloading — safe for active typing.
          -- b_mtime stays stale, but execute_save uses :write! to skip W12.
          vim.v.fcs_choice = "ignore"
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
              merge_into_buffer(bufnr, filepath)
            end
          end)
        else
          -- Normal/command mode: capture edits, let Neovim reload (updates
          -- b_mtime → no more W12 on next :w), then restore merged content.
          local saved = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          vim.v.fcs_choice = "reload"
          vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(bufnr) then return end
            -- Buffer now holds fresh disk content after the reload.
            local disk = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (do_merge(disk, saved)))
            vim.bo[bufnr].modified = true
            vim.notify(
              "[logseq.nvim] Peer changes merged into '"
                .. vim.fn.fnamemodify(filepath, ":t") .. "' — save when ready",
              vim.log.levels.WARN
            )
          end)
        end
      else
        -- Clean buffer + external change → reload (updates b_mtime).
        vim.v.fcs_choice = "reload"
      end
    end,
  })

  -- ── BufWriteCmd ────────────────────────────────────────────────────
  --
  -- Completely replaces Neovim's write path for this file.
  -- The proactive merge in FileChangedShell handles the common case.
  -- This is the safety net for rapid peer writes that slip past checktime.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern = filepath,
    callback = function()
      if vim.api.nvim_get_current_buf() ~= bufnr then return end

      local stat = vim.uv.fs_stat(filepath)
      if stat and disk_is_newer(stat, bufnr) then
        -- Peer change that FileChangedShell didn't catch — merge before writing.
        merge_into_buffer(bufnr, filepath)
      end

      local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      if atomic_write(filepath, final_lines) then
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
    vim.api.nvim_buf_call(bufnr, function()
      -- :write! (bang) bypasses Neovim's stale b_mtime / W12 check.
      -- Safe because BufWriteCmd above handles merging before writing.
      pcall(function() vim.cmd("write!") end)
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

  -- ── Periodic cross-session sync timer ──────────────────────────────
  --
  -- FocusGained and WinEnter only work within a single Neovim process.
  -- Two separate `nvim` instances (e.g. two tmux panes) never fire each
  -- other's focus/window events, so peer writes would only be detected
  -- on CursorHold (4 s idle) — invisible during active editing.
  --
  -- This libuv timer calls :checktime every 3 s regardless of user activity,
  -- ensuring the other session's writes are seen promptly and merged.
  local sync_timer = vim.uv.new_timer()
  sync_timer:start(3000, 3000, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      sync_timer:stop(); sync_timer:close()
      return
    end
    pcall(vim.cmd, "checktime")
  end))

  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = bufnr,
    callback = function()
      if timer_id then vim.fn.timer_stop(timer_id); timer_id = nil end
      if not sync_timer:is_closing() then
        sync_timer:stop(); sync_timer:close()
      end
    end,
  })
end

return M
