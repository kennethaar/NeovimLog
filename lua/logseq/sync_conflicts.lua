local M = {}
local dedup = require("logseq.dedup")

local CONFLICT_SUFFIX = "%.sync%-conflict%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%w+"

function M.launch_diff_tool(original, conflict)
  vim.schedule(function()
    vim.cmd("tabnew")
    local buf_orig = vim.fn.bufadd(original)
    local buf_conf = vim.fn.bufadd(conflict)
    vim.api.nvim_set_current_buf(buf_orig)
    vim.cmd("vsplit")
    local wins = vim.api.nvim_tabpage_list_wins(0)
    vim.api.nvim_win_set_buf(wins[2], buf_conf)
    vim.cmd("windo diffthis")
    vim.cmd("redraw")

    local help_text = { " ]c/[c: Jump", " do: Pull R->L", " :w: Save/Done" }
    local help_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, help_text)
    local help_win = vim.api.nvim_open_win(help_buf, false, {
      relative = 'editor', width = 16, height = #help_text,
      col = vim.o.columns - 18, row = 1,
      style = 'minimal', border = 'single', focusable = false,
    })

    vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWritePost" }, {
      buffer = buf_orig,
      once = true,
      callback = function()
        if vim.api.nvim_win_is_valid(help_win) then vim.api.nvim_win_close(help_win, true) end
        if vim.v.event.wrote or vim.v.cmdbang then 
          os.remove(conflict)
          print("[logseq] Conflict cleaned.")
        end
      end
    })
    vim.api.nvim_set_current_win(wins[1])
  end)
end

function M.auto_resolve_one(conflict_path, original_path, vault)
  local orig = dedup.read_file(original_path)
  local conf = dedup.read_file(conflict_path)
  if not orig then vim.uv.fs_rename(conflict_path, original_path); return "adopted" end
  if not conf or orig == conf then if conf then os.remove(conflict_path) end; return "identical" end
  local is_ff = conf:find(orig, 1, true) or orig:find(conf, 1, true)
  if is_ff then
    dedup.backup_file(original_path, vault, orig)
    local lines = vim.split(orig .. "\n" .. conf, "\n", { plain = true })
    local cleaned = dedup.dedup_lines(lines)
    if dedup.safe_write(original_path, table.concat(cleaned, "\n") .. "\n") then
      os.remove(conflict_path); return "merged"
    end
  end
  return "manual"
end

function M.scan_conflicts(vault)
  if not vault or vault == "" then return {} end
  local results = {}
  for _, dir in ipairs({ vault .. "/pages", vault .. "/journals" }) do
    if vim.fn.isdirectory(dir) == 1 then
      for _, fpath in ipairs(vim.fn.glob(dir .. "/*.sync-conflict-*.md", false, true)) do
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

function M.resolve_all(vault)
  local conflicts = M.scan_conflicts(vault)
  if #conflicts == 0 then return end
  local manual_found = false
  for _, c in ipairs(conflicts) do
    local outcome = M.auto_resolve_one(c.conflict, c.original, vault)
    if outcome == "manual" and not manual_found then
      M.launch_diff_tool(c.original, c.conflict)
      manual_found = true
    end
  end
  if manual_found and #conflicts > 1 then
    vim.notify("Multiple conflicts. Solve this one, then re-scan.", vim.log.levels.WARN)
  end
end

return M
