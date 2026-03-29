--- logseq.nvim embeds
--- Renders {{embed ((uuid))}} and {{embed [[Page]]}} as virtual lines below
--- the embed marker. Source files are never modified.
---
--- Design notes:
---   • Block embeds: resolved asynchronously via grep (jobstart, no shell, no
---     injection) so the main thread is never blocked.
---   • Page embeds: resolved synchronously (single file read — fast).
---   • UUID-level cache: each uuid is grepped at most once per session.
---   • Buffer-level cache (changedtick): no redundant scans on unchanged buffers.
---   • Silent on not-found: no error text clutters the buffer.
---   • BufUnload cleans the buffer cache entry to prevent memory growth.

local M = {}

local EMBED_NS = vim.api.nvim_create_namespace("logseq_embeds")

-- ── Patterns (defined once, reused everywhere) ────────────────────────
-- Require complete closing delimiters so partial typing never matches.
local BLOCK_PAT = "%{%{embed%s*%(%(([^)%s]+)%)%)%s*%}%}"
local PAGE_PAT  = "%{%{embed%s*%[%[(.-)%]%]%s*%}%}"

-- ── Caches ────────────────────────────────────────────────────────────
local _buf_tick  = {}   -- bufnr  → changedtick of last completed render
local _uuid_cache = {}  -- uuid   → string[] (block lines) | false (not found)

local MAX_LINES = 30    -- max source lines shown per embed

-- ── Source resolution ─────────────────────────────────────────────────

--- Read a block from `filepath` whose `id::` property is at line `id_lnum`.
--- Walks upward to find the owning bullet then collects it and its property /
--- continuation lines.
---@param filepath string
---@param id_lnum integer  1-indexed
---@return string[]|nil
local function collect_block_lines(filepath, id_lnum)
  local f = io.open(filepath, "r")
  if not f then return nil end
  local all = {}
  for line in f:lines() do all[#all + 1] = line end
  f:close()

  -- Walk upward to find the bullet that owns this id:: property.
  local block_start = id_lnum
  for i = id_lnum - 1, 1, -1 do
    if all[i]:match("^%s*%- ") then
      block_start = i
      break
    end
  end

  -- Collect bullet + properties/continuations until next sibling or blank line.
  local bullet_indent = all[block_start]:match("^(%s*)%-") or ""
  local collected = { all[block_start] }
  for i = block_start + 1, #all do
    local line = all[i]
    if line:match("^%s*$") then break end
    local sib = line:match("^(%s*)%-")
    if sib and #sib <= #bullet_indent then break end
    collected[#collected + 1] = line
  end
  return collected
end

--- Asynchronously resolve a block UUID and call `callback(lines | nil)`.
--- Uses an argv-based jobstart (no shell involved → no injection possible).
--- Validates the UUID format before touching the filesystem at all.
--- Results are cached per UUID so each vault is searched at most once.
---@param vault string
---@param uuid string
---@param callback fun(lines: string[]|nil)
local function resolve_block_async(vault, uuid, callback)
  -- Only allow standard UUID characters (hex + hyphens).
  if not uuid:match("^[%x%-]+$") then
    callback(nil)
    return
  end

  local cached = _uuid_cache[uuid]
  if cached ~= nil then
    callback(cached or nil)   -- false → not found → nil
    return
  end

  local stdout = {}
  vim.fn.jobstart(
    -- Argv array: arguments go directly to grep, no shell expansion.
    { "grep", "-rn", "--include=*.md", "-m", "1",
      "id:: " .. uuid,
      vault .. "/pages",
      vault .. "/journals" },
    {
      stdout_buffered = true,
      on_stdout = function(_, data) vim.list_extend(stdout, data) end,
      on_exit = function(_, code)
        local first = stdout[1]
        if code ~= 0 or not first or first == "" then
          _uuid_cache[uuid] = false
          callback(nil)
          return
        end
        local filepath, lnum_s = first:match("^([^:]+):(%d+):")
        if not filepath then
          _uuid_cache[uuid] = false
          callback(nil)
          return
        end
        local lines = collect_block_lines(filepath, tonumber(lnum_s))
        _uuid_cache[uuid] = lines or false
        callback(lines)
      end,
    }
  )
end

--- Synchronously read all lines from a page file.
---@param vault string
---@param page_name string  decoded name (may contain namespace slashes)
---@return string[]|nil
local function resolve_page(vault, page_name)
  local encoded = require("logseq.util").encode_filename(page_name)
  local f = io.open(vault .. "/pages/" .. encoded, "r")
  if not f then return nil end
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  return lines
end

-- ── Virtual-line rendering ────────────────────────────────────────────

--- Build the virt_lines array for a single embed.
---@param header string
---@param source_lines string[]
---@return table
local function build_virt_lines(header, source_lines)
  local safe = header:sub(1, 40)
  local virt  = { { { "┌─ " .. safe .. " ", "LogseqEmbedHeader" } } }
  local shown = 0

  for _, line in ipairs(source_lines) do
    if line:match("^%s*id::") then goto continue end  -- skip id:: in display
    if shown >= MAX_LINES then
      virt[#virt + 1] = { { "│  … (truncated)", "LogseqEmbedHeader" } }
      break
    end
    virt[#virt + 1] = { { "│  " .. line, "LogseqEmbedText" } }
    shown = shown + 1
    ::continue::
  end

  virt[#virt + 1] = { { "└" .. ("─"):rep(math.max(4, #safe + 4)), "LogseqEmbedHeader" } }
  return virt
end

-- ── Main render pass ──────────────────────────────────────────────────

local function render_embeds(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if _buf_tick[bufnr] == tick then return end
  _buf_tick[bufnr] = tick   -- claim this tick; async callbacks verify before writing

  local vault = (require("logseq.config").current).vault_path
  if not vault or vault == "" then return end

  vim.api.nvim_buf_clear_namespace(bufnr, EMBED_NS, 0, -1)

  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local lnum = i - 1   -- 0-indexed for extmark

    -- Block embed takes priority; page embed is the else branch on the same line.
    local uuid = line:match(BLOCK_PAT)
    if uuid then
      resolve_block_async(vault, uuid, function(src)
        -- Guard: buffer must still exist and tick must not have changed.
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then return end
        if src then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, EMBED_NS, lnum, 0,
            { virt_lines = build_virt_lines("Block " .. uuid:sub(1, 8) .. "…", src) })
        end
        -- Silent on not-found: no error text written to the buffer.
      end)
    else
      local page_name = line:match(PAGE_PAT)
      if page_name then
        local src = resolve_page(vault, page_name)
        if src then
          vim.api.nvim_buf_set_extmark(bufnr, EMBED_NS, lnum, 0,
            { virt_lines = build_virt_lines(page_name, src) })
        end
        -- Silent on not-found.
      end
    end
  end
end

-- ── Buffer setup ──────────────────────────────────────────────────────

function M.setup_buf(bufnr)
  local grp = vim.api.nvim_create_augroup("LogseqEmbeds_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group    = grp,
    buffer   = bufnr,
    callback = function() vim.schedule(function() render_embeds(bufnr) end) end,
  })

  -- Release cache entry on unload to prevent unbounded memory growth.
  vim.api.nvim_create_autocmd("BufUnload", {
    group    = grp,
    buffer   = bufnr,
    callback = function() _buf_tick[bufnr] = nil end,
  })

  vim.schedule(function() render_embeds(bufnr) end)
end

return M
