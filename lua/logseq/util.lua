--- logseq.nvim shared utilities
--- Single source of truth for path normalization, todo states, and filename decoding.
--- Fixes audit issues #8, #27, #29.

local M = {}

-- ── Path Normalization (audit #8) ─────────────────────────────────────

--- Normalize a path: expand ~, resolve symlinks, standardize slashes, and handle OS case-sensitivity.
---@param p string|nil
---@return string
function M.normalize(p)
  if not p or p == "" then return "" end
  
  local resolved = vim.fn.resolve(vim.fn.expand(p)):gsub("\\", "/")
  
  -- Windows paths are case-insensitive, so we normalize to lowercase to prevent mismatch bugs
  if vim.fn.has("win32") == 1 then 
    resolved = resolved:lower() 
  end
  
  -- Strip trailing slash for consistent directory comparisons
  return resolved:gsub("/$", "")
end

--- Check if bufpath is safely inside vault_path.
---@param bufpath string
---@param vault_path string
---@return boolean
function M.is_vault_file(bufpath, vault_path)
  if not vault_path or vault_path == "" then return false end
  
  local norm_buf = M.normalize(bufpath)
  local norm_vault = M.normalize(vault_path)
  
  -- Use Neovim's native string matching instead of manual sub() math
  return vim.startswith(norm_buf, norm_vault .. "/")
end

-- ── TODO States (audit #27) ──────────────────────────────────────────

M.todo_states        = { "NOW", "LATER", "TODO", "WAITING", "DOING", "DONE", "CANCELLED" }
M.active_todo_states = { "NOW", "LATER", "TODO", "DOING", "WAITING" }

-- ── Filename Decoding (audit #29) ─────────────────────────────────────

--- Decode a Logseq filename back to a page name.
--- "BJJ___Techniques___Triangle.md" → "BJJ/Techniques/Triangle"
---@param filename string
---@return string
function M.decode_filename(filename)
  local name = filename:gsub("%.md$", "")
  name = name:gsub("___", "/")
  
  -- Decode percent-encoded characters
  name = name:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  
  return name
end

-- ── Journal Date Formatting ───────────────────────────────────────────

local _journal_fmt_cache = {}  -- vault_path → string | false ("checked, not found")

--- Read :journal/page-title-format from logseq's config.edn, or nil.
--- Result is cached per vault_path so repeated calls (one per scanned file) are free.
---@param vault_path string
---@return string|nil
function M.read_logseq_journal_fmt(vault_path)
  local cached = _journal_fmt_cache[vault_path]
  if cached ~= nil then return cached or nil end  -- false → nil, string → string
  local path = vault_path .. "/.logseq/config.edn"
  local f = io.open(path, "r")
  if not f then
    _journal_fmt_cache[vault_path] = false
    return nil
  end
  local content = f:read("*a")
  f:close()
  local result = content:match(':journal/page%-title%-format%s+"([^"]+)"')
  _journal_fmt_cache[vault_path] = result or false
  return result
end

--- Apply a Logseq/Java-style date format string to a timestamp.
---@param fmt string
---@param ts integer
---@return string
function M.apply_logseq_fmt(fmt, ts)
  local day = tonumber(os.date("%d", ts))
  local mon = tonumber(os.date("%m", ts))
  local dow = tonumber(os.date("%w", ts)) + 1

  local function ord(n)
    if n == 11 or n == 12 or n == 13 then return n .. "th" end
    local r = n % 10
    if r == 1 then return n .. "st" elseif r == 2 then return n .. "nd"
    elseif r == 3 then return n .. "rd" else return n .. "th" end
  end

  local ML = {"January","February","March","April","May","June","July","August","September","October","November","December"}
  local MS = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
  local DL = {"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"}
  local DS = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"}

  local tokens = {
    {"MMMM", ML[mon]}, {"MMM", MS[mon]}, {"MM", string.format("%02d", mon)},
    {"EEEE", DL[dow]}, {"EEE", DS[dow]},
    {"yyyy", os.date("%Y", ts)}, {"yy", os.date("%y", ts)},
    {"do", ord(day)}, {"dd", string.format("%02d", day)}, {"d", tostring(day)},
  }

  local out, i = {}, 1
  while i <= #fmt do
    local matched = false
    for _, tok in ipairs(tokens) do
      if fmt:sub(i, i + #tok[1] - 1) == tok[1] then
        out[#out + 1] = tok[2]; i = i + #tok[1]; matched = true; break
      end
    end
    if not matched then out[#out + 1] = fmt:sub(i, i); i = i + 1 end
  end
  return table.concat(out)
end

--- Convert a journal filename stem to the page title used in wiki links.
--- e.g. "2024_01_15" → "2024-01-15"  (or "Jan 15th, 2024" depending on vault config)
--- Returns nil if the stem is not a recognisable date.
---@param filename string  stem without .md
---@param vault_path string|nil
---@return string|nil
function M.format_journal_date(filename, vault_path)
  local y, m, d = filename:match("^(%d%d%d%d)[_%-](%d%d)[_%-](%d%d)")
  if not y then return nil end
  local ts  = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local fmt = (vault_path and M.read_logseq_journal_fmt(vault_path)) or "yyyy-MM-dd"
  return M.apply_logseq_fmt(fmt, ts)
end

-- ── Shared property / pattern helpers ────────────────────────────────

--- Case-insensitive lookup in a Logseq block's properties table.
--- Properties are stored with their original casing ("SCHEDULED", "id", …).
---@param props table<string,string>
---@param key_lower string  already-lowercased key
---@return string|nil
function M.prop_ci(props, key_lower)
  for k, v in pairs(props) do
    if k:lower() == key_lower then return v end
  end
  return nil
end

--- Case-insensitive Lua pattern match.
--- Lowercases `str` before matching so callers write readable lowercase patterns
--- instead of [Ss][Cc][Hh][Ee][Dd]… character classes.
---@param str string
---@param pattern string  Lua pattern written for lowercase input
---@return string|nil
function M.match_ci(str, pattern)
  return str:lower():match(pattern)
end

-- ── Filename Encoding/Decoding ────────────────────────────────────────

-- ── EDN dict helpers (for Logseq filters:: property) ────────────────

--- Parse a Logseq-style EDN dict string into a Lua table.
--- Input:  '{"TODO" true, "#project" false}'
--- Output: { ["TODO"] = true, ["#project"] = false }
---@param str string|nil
---@return table<string,boolean>
function M.parse_edn_dict(str)
  local result = {}
  if not str or str == "" then return result end
  for key, val in str:gmatch('"([^"]+)"%s+(true|false)') do
    result[key] = (val == "true")
  end
  return result
end

--- Serialize a Lua bool-valued table to a Logseq-style EDN dict string.
--- Input:  { ["TODO"] = true, ["#project"] = false }
--- Output: '{"TODO" true, "#project" false}'
--- Keys are emitted in sorted order for deterministic output.
---@param t table<string,boolean>
---@return string
function M.serialize_edn_dict(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = string.format('"%s" %s', k, t[k] and "true" or "false")
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- ── Filename Encoding/Decoding ────────────────────────────────────────

--- Encode a page name to its on-disk filename.
--- "BJJ/Techniques/Triangle" → "BJJ___Techniques___Triangle.md"
---@param page_name string
---@return string
function M.encode_filename(page_name)
  return page_name
    :gsub("/", "___")
    -- Only encode characters that are unsafe on common filesystems (Windows: \:*?"<>|).
    -- Logseq preserves everything else (spaces, +, dots, etc.) literally in filenames.
    :gsub('([\\:*?"<>|%z])', function(c)
      return string.format("%%%02X", c:byte())
    end) .. ".md"
end

return M

