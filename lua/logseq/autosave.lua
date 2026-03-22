local M = {}

function M.setup_buf(bufnr)
  local timer_id = nil

  local function execute_save()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified then
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