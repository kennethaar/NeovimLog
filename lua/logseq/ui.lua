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

  local close_btn = "%=%@v:lua.require('logseq.ui').close_win@(:q) ✕ %X"
  
  -- If this buffer just saved, append the checkmark
  if M._saved_buffers[bufnr] then
    return " " .. title .. "  ✓ Saved" .. close_btn
  end

  -- Show current/next calendar event (powered by reminders module)
  local ok, reminders = pcall(require, "logseq.reminders")
  if ok then
    local event_text = reminders.next_meeting_str()
    if event_text ~= "" then
      return " " .. title .. "  │  " .. event_text .. close_btn
    end
  end
  
  return " " .. title .. close_btn
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

function M.close_win()
  vim.cmd("q")
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
  -- Setup dynamic Winbar (first — must not be blocked by syntax errors)
  vim.opt_local.winbar = "%{%v:lua.require('logseq.ui').winbar()%}"

  -- Setup Statusline
  local stl = vim.o.statusline
  if stl == "" then stl = "%<%f %h%m%r%=%-14.(%l,%c%V%) %P" end
  if not stl:match("logseq.ui") then
    vim.opt_local.statusline = stl .. " %=%@v:lua.require('logseq.ui').open_help@ hh %X"
  end

  vim.keymap.set("n", "hh", M.open_help, { buffer = bufnr, desc = "Logseq Help" })

  -- Listen for ANY file save (autosave or manual) and trigger the indicator
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    callback = function(ev)
      M.trigger_save_indicator(ev.buf)
    end
  })

  -- Syntax concealment (wrapped in pcall so a bad rule can't break the rest of setup)
  vim.opt_local.conceallevel = 2

  local ok, err = pcall(function()
    vim.api.nvim_buf_call(bufnr, function()
      -- Hide id:: property lines entirely
      vim.cmd([[syntax match LogseqUID /^\s*id::.*$/ conceal]])

      -- Conceal [[wikilinks]]: hide [[ ]], trim namespace prefix, underline visible name
      vim.cmd([[syntax region LogseqLink matchgroup=LogseqLinkDelim start=/\[\[/ end=/\]\]/ concealends contains=LogseqLinkNS oneline]])
      -- NOTE: Cannot use [[ ]] Lua string here — Vim's \] creates ]] which terminates Lua long strings
      vim.cmd("syntax match LogseqLinkNS /.*\\// contained conceal")

      -- Conceal ((block-refs)): hide (( ))
      vim.cmd([[syntax region LogseqBlockRef matchgroup=LogseqBlockRefDelim start=/((\ze[^(]/ end=/))/ concealends oneline]])

      -- Conceal #tags: hide the # prefix
      vim.cmd([[syntax match LogseqTagHash /#\ze[[:alnum:]_\-\/]/ conceal]])
      vim.cmd([[syntax match LogseqTag /#[[:alnum:]_\-\/]\+/ contains=LogseqTagHash]])
    end)
  end)

  if not ok then
    vim.notify("[logseq.nvim] Syntax conceal error: " .. tostring(err), vim.log.levels.WARN)
  end

  -- Highlights: underline links, refs, and tags so they're visually distinct
  vim.cmd([[highlight default LogseqLink gui=underline cterm=underline]])
  vim.cmd([[highlight default LogseqBlockRef gui=underline,italic cterm=underline]])
  vim.cmd([[highlight default LogseqTag gui=underline cterm=underline]])
  vim.cmd([[highlight default link LogseqLinkDelim Conceal]])
  vim.cmd([[highlight default link LogseqBlockRefDelim Conceal]])
end

return M