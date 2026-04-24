local M = {}

local function check_external_mod()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" or not path:match("%.md$") then return end
  local stats = vim.uv.fs_stat(path)
  if not stats then return end
  
  -- Use vim.uv instead of the deprecated vim.loop
  vim.uv.new_timer():start(0, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.cmd("checktime")
    end
  end))
end

function M.setup(opts)
  -- 1. Auto-read changes from disk (External Sync)
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    group = vim.api.nvim_create_augroup("LogseqSyncCheck", { clear = true }),
    callback = check_external_mod,
  })

  vim.api.nvim_create_autocmd("FileChangedShellPost", {
    callback = function()
      vim.notify("[logseq] File changed on disk (Sync). Reloaded.", vim.log.levels.WARN)
    end,
  })

  -- 2. Auto-save changes to disk 
  vim.api.nvim_create_autocmd({ "FocusLost", "InsertLeave", "BufLeave" }, {
    group = vim.api.nvim_create_augroup("LogseqAutoSave", { clear = true }),
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      -- Only save if the buffer is a modified markdown file with a real path
      if vim.bo[buf].modified and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf):match("%.md$") then
        vim.cmd("silent! update")
      end
    end,
  })

  -- 3. Safe Write and Shutdown Command
  vim.api.nvim_create_user_command("LogseqSaveAndQuit", function()
    -- `wall` safely writes ALL modified buffers
    vim.cmd("silent! wall")
    -- `qa` safely quits all windows (it will only quit if everything is saved)
    vim.cmd("qa")
  end, { desc = "Safely write all open files and quit Neovim" })
end

return M