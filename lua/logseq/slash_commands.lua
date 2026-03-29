--- logseq.nvim slash commands
--- Inline / palette triggered by typing / after whitespace on a bullet line.
--- Uses omnifunc (<C-x><C-o>) so it does not conflict with the [[ completefunc.
---
--- Commands:
---   Dates:       /today  /yesterday  /tomorrow  /now
---   TODO states: /TODO  /DOING  /DONE  /WAITING  /CANCELLED
---   Scheduling:  /scheduled  /deadline
---   Embeds:      /embed-page  /embed-block
---   Links:       /page-ref  /block-ref
---   Formatting:  /bold  /italic  /code  /highlight  /strike  /hr
---   Actions:     /template

local parser = require("logseq.parser")
local util   = require("logseq.util")

local M = {}

-- ── Command registry ──────────────────────────────────────────────────
-- All `word` values are normalised to zero-argument functions at load time
-- so the omnifunc never has to branch on type.
--
-- Fields:
--   name        string    typed after /
--   label       string    shown in the completion menu column
--   word        function()->string  replaces the entire "/name" text
--   cursor_back integer   (optional) move cursor left N cols after insert
--                         (positions caret inside paired chars like **|**)
--   todo_state  string    (optional) set block to this TODO state at front
--   action      string    (optional) post-completion side-effect name

local COMMANDS = {
  -- ── Dates ────────────────────────────────────────────────────────
  { name = "today",
    label = "Today's date",
    word  = function() return os.date("%Y-%m-%d") end },

  { name = "yesterday",
    label = "Yesterday's date",
    word  = function() return os.date("%Y-%m-%d", os.time() - 86400) end },

  { name = "tomorrow",
    label = "Tomorrow's date",
    word  = function() return os.date("%Y-%m-%d", os.time() + 86400) end },

  { name = "now",
    label = "Current time HH:MM",
    word  = function() return os.date("%H:%M") end },

  -- ── TODO states ──────────────────────────────────────────────────
  -- word="" erases the "/STATE" trigger; CompleteDone moves the state
  -- to the front of the block's bullet line (Logseq-correct placement).
  { name = "TODO",      label = "Mark TODO",      word = "", todo_state = "TODO" },
  { name = "DOING",     label = "Mark DOING",     word = "", todo_state = "DOING" },
  { name = "DONE",      label = "Mark DONE",      word = "", todo_state = "DONE" },
  { name = "WAITING",   label = "Mark WAITING",   word = "", todo_state = "WAITING" },
  { name = "CANCELLED", label = "Mark CANCELLED", word = "", todo_state = "CANCELLED" },

  -- ── Scheduling ───────────────────────────────────────────────────
  -- word="" erases the trigger; CompleteDone inserts the property line
  -- on the line immediately below the bullet at indent+2 (Logseq format):
  --   - TODO test
  --     SCHEDULED:: <2026-03-29 Sun>
  { name = "scheduled",
    label = "SCHEDULED:: <date>",
    word  = "",
    property = function() return "SCHEDULED:: <" .. os.date("%Y-%m-%d %a") .. ">" end },

  { name = "deadline",
    label = "DEADLINE:: <date>",
    word  = "",
    property = function() return "DEADLINE:: <" .. os.date("%Y-%m-%d %a") .. ">" end },

  -- ── Embeds ───────────────────────────────────────────────────────
  { name = "embed-page",  label = "{{embed [[Page]]}}", word = "{{embed [[" },
  { name = "embed-block", label = "{{embed ((uuid))}}", word = "{{embed ((" },

  -- ── Links ────────────────────────────────────────────────────────
  { name = "page-ref",  label = "Page link [[...]]",      word = "[[" },
  { name = "block-ref", label = "Block reference ((...)))", word = "((" },

  -- ── Formatting ───────────────────────────────────────────────────
  { name = "bold",      label = "Bold **text**",          word = "****", cursor_back = 2 },
  { name = "italic",    label = "Italic _text_",          word = "__",   cursor_back = 1 },
  { name = "code",      label = "Inline `code`",          word = "``",   cursor_back = 1 },
  { name = "highlight", label = "Highlight ^^text^^",     word = "^^^^", cursor_back = 2 },
  { name = "strike",    label = "Strikethrough ~~text~~", word = "~~~~", cursor_back = 2 },
  { name = "hr",        label = "Horizontal rule ---",    word = "---" },

  -- ── Actions ──────────────────────────────────────────────────────
  -- word="" erases the trigger; CompleteDone fires the template picker.
  { name = "template", label = "Apply a template", word = "", action = "template" },
}

-- Normalise all `word` fields to functions once at module load.
-- This removes the type() branch from the hot omnifunc path.
for _, cmd in ipairs(COMMANDS) do
  if type(cmd.word) ~= "function" then
    local w = cmd.word
    cmd.word = function() return w end
  end
end

-- O(1) lookup by name used in CompleteDone.
local BY_NAME = {}
for _, cmd in ipairs(COMMANDS) do BY_NAME[cmd.name] = cmd end

-- ── Trigger detection — single source of truth ────────────────────────
--
-- Returns the 0-indexed column of the / trigger, or -2 (no valid trigger).
-- Both the omnifunc findstart path AND the TextChangedI autocmd call this
-- function, so the two can never silently diverge.
--
-- Guards:
--   • text after / must be [%a%-]* (letters and hyphens, covers embed-page etc.)
--   • / must be preceded by whitespace or be at the start of content
--   • / must not be inside an open [[wikilink]]
local function find_slash_start()
  local col         = vim.api.nvim_win_get_cursor(0)[2]  -- 0-indexed byte offset
  local text_before = vim.api.nvim_get_current_line():sub(1, col)

  -- Rightmost / followed only by word-chars and hyphens up to the cursor.
  local slash_1idx = text_before:match(".*()[/][%a%-]*$")  -- 1-indexed
  if not slash_1idx then return -2 end

  -- / must be preceded by whitespace or sit at the very start of content.
  local char_before = text_before:sub(slash_1idx - 1, slash_1idx - 1)  -- "" when slash_1idx==1
  if char_before ~= "" and not char_before:match("%s") then return -2 end

  -- / must not be inside an open [[wikilink]].
  if text_before:sub(1, slash_1idx - 1):match("%[%[[^%]]*$") then return -2 end

  return slash_1idx - 1  -- convert 1-indexed to 0-indexed column
end

-- ── Omnifunc ──────────────────────────────────────────────────────────

function M.omnifunc(findstart, base)
  if findstart == 1 then
    return find_slash_start()
  end

  -- `base` contains the leading /; strip it for prefix matching.
  local query = base:sub(2):lower()

  local items = {}
  for _, cmd in ipairs(COMMANDS) do
    if query == "" or vim.startswith(cmd.name:lower(), query) then
      items[#items + 1] = {
        word      = cmd.word(),
        abbr      = "/" .. cmd.name,
        menu      = cmd.label,
        user_data = cmd.name,   -- plain string; looked up in CompleteDone
      }
    end
  end
  return items
end

-- ── Post-completion helpers ───────────────────────────────────────────

--- Insert `value` as a continuation line below the owning block's bullet,
--- after any existing property/continuation lines, before any child bullets.
--- Indented at block.indent+2 (no bullet prefix) — Logseq property format.
local function insert_property(value, bufnr)
  local result = parser.parse_buf(bufnr)
  local row    = vim.api.nvim_win_get_cursor(0)[1]
  local block  = parser.block_at_line(result.blocks, row)
  if not block then return end

  -- Walk forward from the bullet line to find the last own (non-bullet) line.
  local all_lines  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local insert_after = block.line_start
  for i = block.line_start + 1, #all_lines do
    if all_lines[i]:match("^%s*$") then break end    -- blank line ends block
    if all_lines[i]:match("^%s*%- ") then break end  -- bullet = child or next sibling
    insert_after = i
  end

  local new_line = string.rep(" ", block.indent + 2) .. value
  vim.api.nvim_buf_set_lines(bufnr, insert_after, insert_after, false, { new_line })
  vim.api.nvim_win_set_cursor(0, { insert_after + 1, #new_line })
end

--- Move `state` to the front of the owning block's content, replacing any
--- existing TODO state. This is Logseq-correct: the state must sit immediately
--- after "- ", not wherever the user happened to type the slash command.
local function apply_todo_state(state, bufnr)
  local result     = parser.parse_buf(bufnr)
  local row        = vim.api.nvim_win_get_cursor(0)[1]
  local block      = parser.block_at_line(result.blocks, row)
  if not block then return end

  local bline      = vim.api.nvim_buf_get_lines(bufnr, block.line_start - 1, block.line_start, false)[1]
  local indent_str, rest = bline:match("^(%s*)%- (.*)$")
  if not indent_str then return end

  -- Strip any existing TODO state from the front of `rest`.
  for _, s in ipairs(util.todo_states) do
    rest = rest:gsub("^" .. s .. "%s*", "")
  end

  local new_line = indent_str .. "- " .. state .. " " .. vim.trim(rest)
  vim.api.nvim_buf_set_lines(bufnr, block.line_start - 1, block.line_start, false, { new_line })
end

-- ── Buffer setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  vim.bo[bufnr].omnifunc = "v:lua.require'logseq.slash_commands'.omnifunc"

  local grp = vim.api.nvim_create_augroup("LogseqSlash_" .. bufnr, { clear = true })

  -- TextChangedI: delegate trigger detection entirely to find_slash_start()
  -- so there is no duplicate logic between this handler and the omnifunc.
  vim.api.nvim_create_autocmd("TextChangedI", {
    group    = grp,
    buffer   = bufnr,
    callback = function()
      if find_slash_start() < 0 then return end
      vim.schedule(function()
        local keys = vim.fn.pumvisible() == 1
          and "<C-e><C-x><C-o>"
          or  "<C-x><C-o>"
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes(keys, true, false, true), "n", true)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("CompleteDone", {
    group    = grp,
    buffer   = bufnr,
    callback = function()
      local item = vim.v.completed_item
      -- user_data is nil when the popup was dismissed without selecting.
      if not item.user_data then return end

      local cmd_def = BY_NAME[item.user_data]
      -- user_data might come from another completion source (page_search etc.)
      if not cmd_def then return end

      if cmd_def.cursor_back then
        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        pcall(vim.api.nvim_win_set_cursor, 0, { row, col - cmd_def.cursor_back })
      end

      if cmd_def.property then
        insert_property(cmd_def.property(), bufnr)
      end

      if cmd_def.todo_state then
        apply_todo_state(cmd_def.todo_state, bufnr)
      end

      if cmd_def.action == "template" then
        vim.schedule(function()
          pcall(require("logseq.templates").apply_template, bufnr)
        end)
      end
    end,
  })
end

return M
