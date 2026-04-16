local M = {}
local dedup = require("logseq.dedup")

--- Syncthing conflict filename pattern
local CONFLICT_SUFFIX = "%.sync%-conflict%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%w+"

--- Launches a professional conflict resolution workspace with a help popup
function M.launch_diff_tool(original, conflict)
  vim.schedule(function()
    -- Create a new tab and set up the side-by-side diff
    vim.cmd("tabnew")
    local buf_orig = vim.fn.bufadd(original)
    local buf_conf = vim.fn.bufadd(conflict)
    
    vim.api.nvim_set_current_buf(buf_orig)
    vim.cmd("vsplit")
    local wins = vim.api.nvim_tabpage_list_wins(0)
    vim.api.nvim_win_set_buf(wins[2], buf_conf)
    
    vim.cmd("windo diffthis")

    -- 1. Help Popup Content
    local help_text = {
      "  Neovim Diff Quick Reference  ",
      "  ---------------------------  ",
      "  Navigation:                  ",
      "    ]c / [c  : Next / Prev diff",
      "                               ",
      "  Merging:                     ",
      "    do (Obtain): Pull Right -> Left",
      "    dp (Put):    Push Left -> Right",
      "                               ",
      "  Resolution:                  ",
      "    Manual Edit: Type in Left window",
      "    Finish: :w (save) then :tabclose",
    }

    -- 2. Create Floating Window
    local help_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, help_text)
    
    local width = 38
    local height = #help_text
    local help_win = vim.api.nvim_open_win(help_buf, false, {
      relative = 'editor',
      width = width,
      height = height,
      col = vim.o.columns - width - 2,
      row = 2,
      style = 'minimal',
      border = 'rounded',
      focusable = false,
    })

    -- 3. Cleanup: Close help and delete conflict file on save
    vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWritePost" }, {
      buffer = buf_orig,
      once = true,
      callback = function()
        if vim.api.nvim_win_is_valid(help_win) then
          vim.api.nvim_win_close(help_win, true)
        end
        -- Only delete conflict if we actually saved the original
        if vim.v.event.wrote or vim.v.cmdbang then 
          os.remove(conflict)
          vim.notify("[logseq] Conflict resolved and cleaned up.", vim.log.levels.INFO)
        end
      end
    })

    -- Focus the Left window (your main file)
    vim.api.nvim_set_current_win(wins[1])
  end)
end

--- Attempt auto-resolve or trigger diff tool
function M.auto_resolve_one(conflict_path, original_path, vault)
  local orig = dedup.read_file(original_path)
  local conf = dedup.read_file(conflict_path)

  -- Case 1: Original is missing (Syncthing created a new file with conflict)
  if not orig then
    vim.uv.fs_rename(conflict_path, original_path)
    return "adopted"
  end

  -- Case 2: Files are identical (Syncthing false positive)
  if not conf or orig == conf then
    if conf then os.remove(conflict_path) end
    return "identical"
  end

  -- Case 3: Fast-Forward (One file is a strict subset of the other)
  local is_ff = conf:find(orig, 1, true) or orig:find(conf, 1, true)

  if is_ff then
    dedup.backup_file(original_path, vault, orig)
    local lines = vim.split(orig .. "\n" .. conf, "\n", { plain = true })
    local cleaned, _ = dedup.dedup_lines(lines)
    local content = table.concat(cleaned, "\n") .. "\n"
    
    if dedup.safe_write(original_path, content) then
      os.remove(conflict_path)
      return "merged"
    end
  end

  -- Case 4: Diverged (Manual 3-way Diff)
  M.launch_diff_tool(original_path, conflict_path)
  return "manual"
end

--- Scan vault for Syncthing conflict files
function M.scan_conflicts(vault)
  if not vault or vault == "" then return {} end
  local results = {}
  for _, dir in ipairs({ vault .. "/pages", vault .. "/journals" }) do
    if vim.fn.isdirectory(dir) == 1 then
      local pattern = dir .. "/*.sync-conflict-*.md"
      for _, fpath in ipairs(vim.fn.glob(pattern, false, true)) do
        local name = vim.fn.fnamemodify(fpath, ":t")
        if name:match(CONFLICT_SUFFIX) then
          local original = dir .. "/" .. name:gsub(CONFLICT_SUFFIX, "")
          results[#results + 1] = { conflict = fpath, original = original }
        end
      end
    end
  end
  return results
end

--- Resolve all conflicts in the vault
function M.resolve_all(vault)
  local conflicts = M.scan_conflicts(vault)
  if #conflicts == 0 then return end

  local manual_count = 0
  for _, c in ipairs(conflicts) do
    local outcome = M.auto_resolve_one(c.conflict, c.original, vault)
    if outcome == "manual" then manual_count = manual_count + 1 end
  end

  if manual_count > 0 then
    vim.notify(("[logseq] %d conflicts require manual review."):format(manual_count), vim.log.levels.WARN)
  end
  
  vim.cmd("checktime")
end

return M