--- logseq.nvim slash commands
--- Inline / palette triggered by typing / after whitespace on a bullet line.
--- Uses omnifunc (<C-x><C-o>) so it does not conflict with the [[ completefunc.
---
--- Supported commands:
---   Dates:       /today  /yesterday  /tomorrow  /now
---   TODO states: /TODO  /DOING  /DONE  /WAITING  /CANCELLED
---   Scheduling:  /scheduled  /deadline
---   Embeds:      /embed-page  /embed-block
---   Links:       /page-ref  /block-ref
---   Formatting:  /bold  /italic  /code  /highlight  /strike  /hr
---   Actions:     /template

local M = {}

-- ── Command registry ──────────────────────────────────────────────────
-- Fields:
--   name        string   typed after /
--   label       string   shown in the completion menu (menu column)
--   word        string|function  text that replaces "/name"; function called at
--                                selection time so dates are always current
--   cursor_back integer  (optional) move cursor left N chars after insertion
--                        (positions inside paired chars like **** → *|*)
--   action      string   (optional) post-completion action name (no text inserted)

local COMMANDS = {
  -- ── Dates & times ────────────────────────────────────────────────
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
  { name = "TODO",       label = "Mark TODO",      word = "TODO " },
  { name = "DOING",      label = "Mark DOING",     word = "DOING " },
  { name = "DONE",       label = "Mark DONE",      word = "DONE " },
  { name = "WAITING",    label = "Mark WAITING",   word = "WAITING " },
  { name = "CANCELLED",  label = "Mark CANCELLED", word = "CANCELLED " },

  -- ── Scheduling ───────────────────────────────────────────────────
  { name = "scheduled",
    label = "SCHEDULED:: <date>",
    word  = function() return "SCHEDULED:: <" .. os.date("%Y-%m-%d") .. ">" end },

  { name = "deadline",
    label = "DEADLINE:: <date>",
    word  = function() return "DEADLINE:: <" .. os.date("%Y-%m-%d") .. ">" end },

  -- ── Embeds ───────────────────────────────────────────────────────
  { name = "embed-page",
    label = "{{embed [[Page]]}}",
    word  = "{{embed [[" },

  { name = "embed-block",
    label = "{{embed ((uuid))}}",
    word  = "{{embed ((" },

  -- ── Links ────────────────────────────────────────────────────────
  { name = "page-ref",
    label = "Page link [[...]]",
    word  = "[[" },

  { name = "block-ref",
    label = "Block reference ((...)))",
    word  = "((" },

  -- ── Formatting ───────────────────────────────────────────────────
  { name = "bold",
    label = "Bold **text**",
    word  = "****",
    cursor_back = 2 },

  { name = "italic",
    label = "Italic /text/",
    word  = "__",
    cursor_back = 1 },

  { name = "code",
    label = "Inline `code`",
    word  = "``",
    cursor_back = 1 },

  { name = "highlight",
    label = "Highlight ^^text^^",
    word  = "^^^^",
    cursor_back = 2 },

  { name = "strike",
    label = "Strikethrough ~~text~~",
    word  = "~~~~",
    cursor_back = 2 },

  { name = "hr",
    label = "Horizontal rule ---",
    word  = "---" },

  -- ── Actions ──────────────────────────────────────────────────────
  { name = "template",
    label = "Apply a template",
    word  = "",
    action = "template" },
}

-- O(1) lookup by name for CompleteDone handler.
local BY_NAME = {}
for _, cmd in ipairs(COMMANDS) do BY_NAME[cmd.name] = cmd end

-- ── Omnifunc ──────────────────────────────────────────────────────────

--- Find the 0-indexed column of the / trigger before the cursor, or -2.
--- Guards:
---   • / must be preceded by whitespace (or be at the very start of content)
---   • / must not be inside an open [[wikilink]]
local function find_slash_start()
  local col          = vim.api.nvim_win_get_cursor(0)[2]  -- 0-indexed
  local line         = vim.api.nvim_get_current_line()
  local text_before  = line:sub(1, col)                   -- chars before cursor

  -- Find the last / that could be a trigger.
  -- Pattern .*() is greedy, so this gives us the rightmost /.
  local slash_1idx = text_before:match(".*()[/]%a*%-?%a*$")  -- 1-indexed
  if not slash_1idx then return -2 end

  -- Guard: / must be preceded by whitespace or be at position 1.
  local char_before = slash_1idx > 1 and text_before:sub(slash_1idx - 1, slash_1idx - 1) or ""
  if char_before ~= "" and not char_before:match("%s") then return -2 end

  -- Guard: / must not be inside [[...]].
  local before_slash = text_before:sub(1, slash_1idx - 1)
  if before_slash:match("%[%[[^%]]*$") then return -2 end

  return slash_1idx - 1  -- convert to 0-indexed column
end

function M.omnifunc(findstart, base)
  if findstart == 1 then
    return find_slash_start()
  end

  -- base includes the leading /, strip it for matching.
  local query = base:sub(2):lower()

  local items = {}
  for _, cmd in ipairs(COMMANDS) do
    local name_lower = cmd.name:lower()
    if query == "" or name_lower:sub(1, #query) == query then
      local word = type(cmd.word) == "function" and cmd.word() or cmd.word
      items[#items + 1] = {
        word      = word,
        abbr      = "/" .. cmd.name,
        menu      = cmd.label,
        user_data = cmd.name,   -- string; looked up in CompleteDone
      }
    end
  end

  return items
end

-- ── Buffer setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  -- Register omnifunc for this buffer.
  vim.bo[bufnr].omnifunc = "v:lua.require'logseq.slash_commands'.omnifunc"

  local grp = vim.api.nvim_create_augroup("LogseqSlash_" .. bufnr, { clear = true })

  -- Trigger completion whenever /word is typed after whitespace.
  vim.api.nvim_create_autocmd("TextChangedI", {
    group    = grp,
    buffer   = bufnr,
    callback = function()
      local col         = vim.api.nvim_win_get_cursor(0)[2]
      local text_before = vim.fn.getline("."):sub(1, col)

      -- Must match /alphanum-chars at end, preceded by whitespace or start.
      if not (text_before:match("[%s]/%a*%-?%a*$") or text_before:match("^%s*%- /%a*%-?%a*$")) then
        return
      end
      -- Don't fire inside [[...]].
      if text_before:match("%[%[[^%]]*$") then return end

      vim.schedule(function()
        -- Dismiss any open popup first, then open the slash menu.
        local keys = vim.fn.pumvisible() == 1
          and "<C-e><C-x><C-o>"
          or  "<C-x><C-o>"
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes(keys, true, false, true), "n", true)
      end)
    end,
  })

  -- Post-completion: handle cursor repositioning and actions.
  vim.api.nvim_create_autocmd("CompleteDone", {
    group    = grp,
    buffer   = bufnr,
    callback = function()
      local item = vim.v.completed_item
      if not item then return end

      local cmd_name = item.user_data
      if type(cmd_name) ~= "string" then return end

      local cmd_def = BY_NAME[cmd_name]
      if not cmd_def then return end

      -- Reposition cursor inside paired formatting chars (e.g. ****  →  **|**).
      if cmd_def.cursor_back and cmd_def.cursor_back > 0 then
        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        pcall(vim.api.nvim_win_set_cursor, 0, { row, col - cmd_def.cursor_back })
      end

      -- Fire deferred actions.
      if cmd_def.action == "template" then
        vim.schedule(function()
          pcall(require("logseq.templates").apply_template,
                vim.api.nvim_get_current_buf())
        end)
      end
    end,
  })
end

return M
