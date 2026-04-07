--- logseq.prev_metrics
--- Shows the most-recently-logged value for each property as dimmed virtual
--- text at the end of the line. Looks back through past journal files so the
--- user can compare today's entry against the last time they filled a field in.
---
--- Only activates for files inside <vault>/journals/.

local M = {}
local config = require("logseq.config")
local parser = require("logseq.parser")
local uv = vim.uv or vim.loop

local NS = vim.api.nvim_create_namespace("logseq_prev_metrics")
local MAX_LOOKBACK_DAYS = 30

-- Cache: date_str → table<key_lower, value>
-- Persists for the session; cleared when a journal buffer is unloaded.
local _day_cache = {}

-- ── Helpers ───────────────────────────────────────────────────────────────

local function is_journal_buf(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local vault = config.current and config.current.vault_path
  if not vault then return false end
  local journals_dir = vim.fs.joinpath(vault, "journals") .. "/"
  return path:sub(1, #journals_dir) == journals_dir
end

-- Read a file from disk without loading it into a buffer.
local function read_and_parse(filepath)
  local stat = uv.fs_stat(filepath)
  if not stat then return nil end
  local fd = uv.fs_open(filepath, "r", 438)
  if not fd then return nil end
  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not content then return nil end
  local lines = vim.split(content, "\n", { plain = true })
  return parser.parse(lines)
end

-- Walk all blocks and collect every property key → value pair.
-- Earlier occurrences win (first block with a key is the one shown).
local function collect_properties(parsed)
  local props = {}
  local function walk(blocks)
    for _, block in ipairs(blocks) do
      for k, v in pairs(block.properties or {}) do
        local kl = k:lower()
        if not props[kl] then props[kl] = v end
      end
      walk(block.children or {})
    end
  end
  walk(parsed.blocks or {})
  for k, v in pairs(parsed.page_properties or {}) do
    local kl = k:lower()
    if not props[kl] then props[kl] = v end
  end
  return props
end

-- Return cached (or freshly-read) properties for the given date string.
local function get_day_props(date_str)
  if _day_cache[date_str] ~= nil then return _day_cache[date_str] end
  local vault = config.current and config.current.vault_path
  if not vault then return {} end
  local filepath = vim.fs.joinpath(vault, "journals", date_str .. ".md")
  local parsed = read_and_parse(filepath)
  local props = parsed and collect_properties(parsed) or {}
  _day_cache[date_str] = props
  return props
end

-- Build a map of key_lower → { value, date_str } for the most recent entry
-- of each property found in the past MAX_LOOKBACK_DAYS journal files.
-- The current buffer's own date is skipped so today's value is never shown
-- as "previous".
local function build_prev_map(skip_date_str)
  local fmt = (config.current and config.current.journal_format) or "%Y_%m_%d"
  local result = {}
  for i = 1, MAX_LOOKBACK_DAYS do
    local t = os.time() - i * 86400
    local date_str = os.date(fmt, t)
    if date_str ~= skip_date_str then
      local props = get_day_props(date_str)
      for kl, v in pairs(props) do
        if not result[kl] then
          result[kl] = { value = v, date_str = date_str }
        end
      end
    end
  end
  return result
end

-- Derive the journal date string from the buffer's file path, e.g.
-- ".../journals/2026_04_07.md" → "2026_04_07".  Returns nil for non-journal.
local function buf_date_str(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  return path:match("[/\\]journals[/\\](.+)%.md$")
end

-- ── Rendering ─────────────────────────────────────────────────────────────

local function render(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

  local skip = buf_date_str(bufnr)
  local prev_map = build_prev_map(skip)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    local key = line:match("^%s*([%w_%-]+)::")
    if key then
      local entry = prev_map[key:lower()]
      if entry then
        vim.api.nvim_buf_set_extmark(bufnr, NS, i - 1, 0, {
          virt_text = { { "  ← " .. entry.value, "LogseqPrevMetric" } },
          virt_text_pos = "eol",
          priority = 10,
        })
      end
    end
  end
end

-- ── Module setup ──────────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  if not is_journal_buf(bufnr) then return end

  vim.api.nvim_set_hl(0, "LogseqPrevMetric", { link = "Comment", default = true })

  local group = vim.api.nvim_create_augroup("LogseqPrevMetrics_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "TextChanged" }, {
    group = group,
    buffer = bufnr,
    callback = function() render(bufnr) end,
  })

  -- Drop cached data for past days when the buffer is unloaded so stale
  -- values don't linger if the user edits a past journal file.
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function() _day_cache = {} end,
  })

  render(bufnr)
end

return M
