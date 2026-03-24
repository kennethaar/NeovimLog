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

M.todo_states = { "TODO", "WAITING", "DOING", "DONE", "CANCELLED" }
M.active_todo_states = { "TODO", "DOING", "WAITING" }

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

--- Encode a page name to its on-disk filename.
--- "BJJ/Techniques/Triangle" → "BJJ___Techniques___Triangle.md"
---@param page_name string
---@return string
function M.encode_filename(page_name)
  return page_name
    :gsub("/", "___")
    -- CRITICAL FIX: Allow spaces (' ') and dots ('%.') to pass through unencoded.
    -- Logseq natively preserves spaces in filenames. Encoding them to %20 breaks compatibility.
    :gsub("([^%w_%-%. ])", function(c)
      return string.format("%%%02X", c:byte())
    end) .. ".md"
end

return M

