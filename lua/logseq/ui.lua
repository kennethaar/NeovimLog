local M = {}

-- Store the temporary save states for buffers
M._saved_buffers = {}

function M.winbar()
  -- Neovim 0.8+ provides statusline_winid, letting us know exactly which window's bar is drawing
  local winid = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local name = vim.fn.fnamemodify(filepath, ":t")
  if name == "" then return "" end
  
  local title = name:gsub("%.md$", ""):gsub("---", "/")
  
  -- If this buffer just saved, append the checkmark
  if M._saved_buffers[bufnr] then
    return " " .. title .. "  ✓ Saved"
  end
  
  return " " .. title
end

-- This is called by the autocommand to trigger the UI flash
function M.trigger_save_indicator(bufnr)
  M._saved_buffers[bufnr] = true
  vim.cmd("redraw!") -- Force the winbar to update immediately

  -- Clear the indicator after 1.5 seconds (1500 ms)
  vim.defer_fn(function()
    M._saved_buffers[bufnr] = nil
    -- vim.schedule ensures we don't cause async drawing errors
    vim.schedule(function() 
       if vim.api.nvim_buf_is_valid(bufnr) then
          vim.cmd("redraw!") 
       end
    end)
  end, 1500)
end

function M.open_help()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local help_file = vim.fn.fnamemodify(src, ":p:h:h") .. "/README.md" 
  
  if vim.fn.filereadable(help_file) == 1 then
    vim.cmd("vsplit " .. vim.fn.fnameescape(help_file))
  else
    local msg = string.format(
      "Logseq Mode Active!\n" ..
      "• Folding: za\n" ..
      "• Move Block: <Alt-Up/Down>\n" ..
      "• Indent: Tab / Shift-Tab\n" ..
      "• Search Link: [[\n" ..
      "• Add link by selcting text and hitting enter\n" ..
      "• Cycle TODO state by hitting Ctrl + T\n" ..
      "• Trigger calsync with :Calsync\n" ..
      "(Note: Could not locate README at %s)", help_file
    )
    vim.notify(msg, vim.log.levels.INFO)
  end
end

function M.setup_buf(bufnr)
vim.opt_local.conceallevel = 2
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd([[syntax match LogseqUID /^\s*id::.*$/ conceal]])
    vim.fn.matchadd("LogseqTime", [[\d\{2}:\d\{2}-\d\{2}:\d\{2}]])
    vim.fn.matchadd("LogseqTime", [[(Heldags)]])
  end)
  vim.api.nvim_set_hl(0, "LogseqTime", { fg = "#e06c60" })

  -- Setup dynamic Winbar
  vim.opt_local.winbar = "%{%v:lua.require('logseq.ui').winbar()%}"
  
  -- Setup Statusline
  local stl = vim.o.statusline
  if stl == "" then stl = "%<%f %h%m%r%=%-14.(%l,%c%V%) %P" end
  if not stl:match("logseq.ui") then
    vim.opt_local.statusline = stl .. " %=%@v:lua.require('logseq.ui').open_help@ hh %X"
  end

  vim.keymap.set("n", "hh", M.open_help, { buffer = bufnr, desc = "Logseq Help" })

  -- NEW: Listen for ANY file save (autosave or manual) and trigger the indicator
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    callback = function(ev)
      M.trigger_save_indicator(ev.buf)
    end
  })
end

return M