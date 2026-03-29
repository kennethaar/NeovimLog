--- logseq.nvim embeds
--- Renders {{embed ((uuid))}} and {{embed [[Page]]}} as virtual text (virt_lines)
--- below the embed marker line. Content is read-only display; the source files
--- are never modified.

local M = {}

local EMBED_NS = vim.api.nvim_create_namespace("logseq_embeds")

-- Per-buffer render cache keyed by changedtick to avoid redundant work.
local _cache = {} -- bufnr → changedtick

-- ── Source resolution ─────────────────────────────────────────────────

--- Find the block that owns `id:: <uuid>` and return its display lines.
--- Searches pages/ and journals/ synchronously via grep.
---@param vault string
---@param uuid string
---@return string[]|nil
local function resolve_block_uuid(vault, uuid)
  local pages_dir    = vault .. "/pages"
  local journals_dir = vault .. "/journals"
  -- Escape uuid for shell (uuids are hex+dashes, safe as-is)
  local cmd = string.format(
    "grep -rn --include='*.md' -m 1 'id:: %s' '%s' '%s' 2>/dev/null",
    uuid, pages_dir, journals_dir
  )
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 or out == "" then return nil end

  local filepath, lnum_s = out:match("^([^:]+):(%d+):")
  if not filepath then return nil end

  local lnum = tonumber(lnum_s)
  local f = io.open(filepath, "r")
  if not f then return nil end
  local all = {}
  for line in f:lines() do all[#all + 1] = line end
  f:close()

  -- The grep hit the id:: line; walk upward to find the owning bullet.
  local block_start = lnum
  for i = lnum - 1, 1, -1 do
    if all[i]:match("^%s*%- ") then
      block_start = i
      break
    end
  end

  -- Collect bullet + property/continuation lines until the next sibling/blank.
  local bullet_indent = all[block_start]:match("^(%s*)%-") or ""
  local collected = { all[block_start] }
  for i = block_start + 1, #all do
    local line = all[i]
    if line:match("^%s*$") then break end
    local sib_ind = line:match("^(%s*)%-")
    if sib_ind and #sib_ind <= #bullet_indent then break end
    collected[#collected + 1] = line
  end
  return collected
end

--- Read all lines of a page file.
---@param vault string
---@param page_name string  decoded page name (may contain namespace slashes)
---@return string[]|nil
local function resolve_page(vault, page_name)
  local util = require("logseq.util")
  local encoded = util.encode_filename(page_name) -- encodes "/" → "___"
  local path = vault .. "/pages/" .. encoded
  local f = io.open(path, "r")
  if not f then return nil end
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  return lines
end

-- ── Virtual text rendering ────────────────────────────────────────────

local MAX_EMBED_LINES = 30 -- maximum source lines shown per embed

--- Build the virt_lines table for an embed block.
---@param header string  label shown in the top border
---@param source_lines string[]
---@return table  list of virt_line entries for nvim_buf_set_extmark
local function build_virt_lines(header, source_lines)
  local virt = {}
  local safe_header = header:sub(1, 40)
  virt[#virt + 1] = { { "┌─ " .. safe_header .. " ", "LogseqEmbedHeader" } }

  local shown = 0
  for _, line in ipairs(source_lines) do
    -- Skip id:: property lines in the display
    if not line:match("^%s*id::") then
      if shown >= MAX_EMBED_LINES then
        virt[#virt + 1] = { { "│  … (truncated)", "LogseqEmbedHeader" } }
        break
      end
      virt[#virt + 1] = { { "│  " .. line, "LogseqEmbedText" } }
      shown = shown + 1
    end
  end

  virt[#virt + 1] = { { "└" .. ("─"):rep(math.max(4, #safe_header + 4)), "LogseqEmbedHeader" } }
  return virt
end

-- ── Main render pass ──────────────────────────────────────────────────

--- Scan `bufnr` for embed markers and render virtual content below each one.
---@param bufnr integer
local function render_embeds(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if _cache[bufnr] == tick then return end

  vim.api.nvim_buf_clear_namespace(bufnr, EMBED_NS, 0, -1)

  local config = require("logseq.config").current
  local vault  = config.vault_path
  if not vault or vault == "" then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    -- ── Block embed: {{embed ((uuid))}} ──────────────────────────────
    local uuid = line:match("%{%{embed%s*%(%(([^)%s]+)%)%)%s*%}%}")
    if uuid then
      local src = resolve_block_uuid(vault, uuid)
      if src then
        local vl = build_virt_lines("Block " .. uuid:sub(1, 8) .. "…", src)
        vim.api.nvim_buf_set_extmark(bufnr, EMBED_NS, i - 1, 0, { virt_lines = vl })
      else
        vim.api.nvim_buf_set_extmark(bufnr, EMBED_NS, i - 1, 0, {
          virt_lines = { { { "┌─ Block not found: " .. uuid, "LogseqEmbedHeader" } } },
        })
      end
    end

    -- ── Page embed: {{embed [[Page Name]]}} ──────────────────────────
    local page_name = line:match("%{%{embed%s*%[%[(.-)%]%]%s*%}%}")
    if page_name then
      local src = resolve_page(vault, page_name)
      if src then
        local vl = build_virt_lines(page_name, src)
        vim.api.nvim_buf_set_extmark(bufnr, EMBED_NS, i - 1, 0, { virt_lines = vl })
      else
        vim.api.nvim_buf_set_extmark(bufnr, EMBED_NS, i - 1, 0, {
          virt_lines = { { { "┌─ Page not found: " .. page_name, "LogseqEmbedHeader" } } },
        })
      end
    end
  end

  _cache[bufnr] = tick
end

-- ── Buffer setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local grp = vim.api.nvim_create_augroup("LogseqEmbeds_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group    = grp,
    buffer   = bufnr,
    callback = function() vim.schedule(function() render_embeds(bufnr) end) end,
  })

  -- Initial render deferred so the buffer is fully loaded.
  vim.schedule(function() render_embeds(bufnr) end)
end

return M
