--- logseq.nvim page search
--- Fuzzy page completion triggered by [[ in insert mode.

local config = require("logseq.config")
local util = require("logseq.util")

local M = {}

-- ── Scoring ───────────────────────────────────────────────────────────

local function get_match_score(str, pattern)
  if not pattern or pattern == "" then return 0 end
  str = str:lower()
  pattern = pattern:lower()

  local exact_idx = str:find(pattern, 1, true)
  if exact_idx then return 10000 - exact_idx end

  local total_score = 0

  for word in pattern:gmatch("%S+") do
    local word_idx = str:find(word, 1, true)
    if word_idx then
      total_score = total_score + (1000 - word_idx)
    else
      local p_idx = 1
      local matched = false
      local char_score = 0
      local last_match_idx = -1

      for i = 1, #str do
        if str:sub(i, i) == word:sub(p_idx, p_idx) then
          char_score = char_score + (last_match_idx == i - 1 and 10 or 1)
          last_match_idx = i
          p_idx = p_idx + 1
          if p_idx > #word then
            matched = true
            break
          end
        end
      end
      if not matched then return -1 end
      total_score = total_score + char_score
    end
  end

  return total_score
end

-- ── Vault scanner ─────────────────────────────────────────────────────

local function get_all_pages()
  local vault = config.current.vault_path
  if not vault or vault == "" then return {} end

  local items = {}
  local function scan_dir(dir)
    if vim.fn.isdirectory(dir) == 0 then return end
    local files = vim.fn.glob(dir .. "/*.md", true, true)
    for _, file in ipairs(files) do
      local basename = vim.fn.fnamemodify(file, ":t")
      table.insert(items, util.decode_filename(basename))
    end
  end

  scan_dir(vault .. "/pages")
  scan_dir(vault .. "/journals")
  return items
end

-- ── Completion function ───────────────────────────────────────────────

function M.completefunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local text_before_cursor = line:sub(1, col)
    local start_idx = text_before_cursor:match(".*%[%[()")
    if start_idx then return start_idx - 1 end
    return col
  end

  local pages = get_all_pages()
  local matches = {}

  for _, page in ipairs(pages) do
    local score = get_match_score(page, base)
    if score >= 0 then
      table.insert(matches, {
        word = page .. "]]",
        abbr = page,
        icase = 1,
        score = score,
      })
    end
  end

  table.sort(matches, function(a, b)
    if a.score == b.score then return a.abbr < b.abbr end
    return a.score > b.score
  end)

  return matches
end

-- ── Buffer setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  vim.opt_local.completeopt = { "menuone", "noinsert", "noselect" }
  vim.bo[bufnr].completefunc = "v:lua.require'logseq.page_search'.completefunc"

  local group = vim.api.nvim_create_augroup("LogseqPageSearch_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = bufnr,
    callback = function()
      local col = vim.fn.col('.') - 1
      local text_before = vim.fn.getline('.'):sub(1, col)

      if not text_before:match("%[%[[^%]]*$") then return end

      vim.schedule(function()
        local keys = vim.fn.pumvisible() == 1 and "<C-e><C-x><C-u>" or "<C-x><C-u>"
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", true)
      end)
    end,
  })
end

return M
