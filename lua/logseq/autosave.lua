local M = {}

function M.setup_buf(bufnr)
  local timer_id = nil

  -- Before writing, check if the file on disk has lines appended externally
  -- (e.g. by termux-url-opener) that aren't in the buffer yet. If the file's
  -- content up to len(buffer) matches the buffer exactly, pull the extra lines
  -- in so autosave doesn't overwrite them.
  local function merge_external_appends()
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath == "" then return end

    local f = io.open(filepath, "r")
    if not f then return end
    local file_content = f:read("*all")
    f:close()

    -- Split file into lines
    local file_lines = {}
    for line in (file_content .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(file_lines, line)
    end
    while #file_lines > 0 and file_lines[#file_lines] == "" do
      table.remove(file_lines)
    end

    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    -- Only act if file has strictly more lines than the buffer
    if #file_lines <= #buf_lines then return end

    -- Verify the buffer content matches the start of the file (clean append, no conflict)
    for i = 1, #buf_lines do
      if (file_lines[i] or "") ~= buf_lines[i] then return end
    end

    -- Append the extra lines from disk into the buffer
    local extra = {}
    for i = #buf_lines + 1, #file_lines do
      table.insert(extra, file_lines[i])
    end
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, extra)
  end

  -- The actual save execution
  local function execute_save()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified then
      merge_external_appends()
      vim.api.nvim_buf_call(bufnr, function()
        pcall(function() vim.cmd("write") end)
      end)
    end
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