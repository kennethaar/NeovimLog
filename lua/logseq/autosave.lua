local M = {}
local function check_external_mod()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" or not path:match("%.md$") then return end
  local stats = vim.uv.fs_stat(path)
  if not stats then return end
  vim.loop.new_timer():start(0, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.cmd("checktime")
    end
  end))
end
function M.setup(opts)
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    group = vim.api.nvim_create_augroup("LogseqSyncCheck", { clear = true }),
    callback = check_external_mod,
  })
  vim.api.nvim_create_autocmd("FileChangedShellPost", {
    callback = function()
      vim.notify("[logseq] File changed on disk (Sync). Reloaded.", vim.log.levels.WARN)
    end,
  })
end
return M
