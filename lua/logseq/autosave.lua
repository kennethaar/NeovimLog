local M = {}

local function uv_write(path, lines)
  local uv = vim.uv
  local content = table.concat(lines, "\n") .. "\n"
  local fd = uv.fs_open(path, "w", 438)
  if not fd then return false end
  uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
  return true
end

function M.setup_buf(bufnr)
  local group = vim.api.nvim_create_augroup("logseq_save_" .. bufnr, { clear = true })
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  local timer = vim.uv.new_timer()
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave", "BufLeave", "FocusLost" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      timer:stop()
      timer:start(2000, 0, vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified then
          uv_write(filepath, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
          vim.bo[bufnr].modified = false
        end
      end))
    end,
  })

  vim.api.nvim_create_autocmd("BufUnload", { group = group, buffer = bufnr, callback = function() timer:stop(); timer:close() end })
end

return M
