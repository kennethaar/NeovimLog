local M = {}

function M.normalize(p)
  if not p or p == "" then return "" end
  local res = vim.fn.resolve(vim.fn.expand(p)):gsub("\\", "/")
  if vim.fn.has("win32") == 1 then res = res:lower() end
  return res:gsub("/$", "")
end

function M.is_vault_file(bp, vp)
  if not vp or vp == "" then return false end
  return vim.startswith(M.normalize(bp), M.normalize(vp) .. "/")
end

M.todo_states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" }
M.active_todo_states = { "TODO", "DOING", "WAITING" }

function M.get_vault_files(vault_path)
  return vim.iter({ "pages", "journals" })
    :map(function(d) return vim.fs.joinpath(vault_path, d) end)
    :filter(function(d) return vim.fn.isdirectory(d) == 1 end)
    :map(function(d) return vim.fn.glob(vim.fs.joinpath(d, "*.md"), false, true) end)
    :flatten()
    :totable()
end

function M.decode_filename(f)
  local n = f:gsub("%.md$", ""):gsub("___", "/")
  return (n:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function M.encode_filename(p)
  return p:gsub("/", "___"):gsub('([\\:*?"<>|%z])', function(c)
    return string.format("%%%02X", c:byte())
  end) .. ".md"
end

local _journal_fmt_cache = {}
function M.read_logseq_journal_fmt(vault_path)
  if _journal_fmt_cache[vault_path] ~= nil then return _journal_fmt_cache[vault_path] or nil end
  local path = vim.fs.joinpath(vault_path, ".logseq", "config.edn")
  local f = io.open(path, "r")
  if not f then _journal_fmt_cache[vault_path] = false; return nil end
  local content = f:read("*a"); f:close()
  local result = content:match(':journal/page%-title%-format%s+"([^"]+)"')
  _journal_fmt_cache[vault_path] = result or false
  return result
end

function M.apply_logseq_fmt(fmt, ts)
  local day, mon, dow = tonumber(os.date("%d", ts)), tonumber(os.date("%m", ts)), tonumber(os.date("%w", ts)) + 1
  local ord = function(n)
    if n >= 11 and n <= 13 then return n .. "th" end
    local r = n % 10
    return n .. (r == 1 and "st" or r == 2 and "nd" or r == 3 and "rd" or "th")
  end
  local ML = {"January","February","March","April","May","June","July","August","September","October","November","December"}
  local MS = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
  local DL = {"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"}
  local DS = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"}
  local tokens = { {"MMMM", ML[mon]}, {"MMM", MS[mon]}, {"MM", string.format("%02d", mon)}, {"EEEE", DL[dow]}, {"EEE", DS[dow]}, {"yyyy", os.date("%Y", ts)}, {"yy", os.date("%y", ts)}, {"do", ord(day)}, {"dd", string.format("%02d", day)}, {"d", tostring(day)} }
  local out, i = {}, 1
  while i <= #fmt do
    local matched = false
    for _, tok in ipairs(tokens) do
      if vim.startswith(fmt:sub(i), tok[1]) then table.insert(out, tok[2]); i = i + #tok[1]; matched = true; break end
    end
    if not matched then table.insert(out, fmt:sub(i, i)); i = i + 1 end
  end
  return table.concat(out)
end

function M.format_journal_date(filename, vault_path)
  local y, m, d = filename:match("^(%d%d%d%d)[_%-](%d%d)[_%-](%d%d)")
  if not y then return nil end
  local ts = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local fmt = (vault_path and M.read_logseq_journal_fmt(vault_path)) or "yyyy-MM-dd"
  return M.apply_logseq_fmt(fmt, ts)
end

function M.prop_ci(props, key_lower)
  for k, v in pairs(props) do if k:lower() == key_lower then return v end end
end

function M.match_ci(str, pattern) return str:lower():match(pattern) end

function M.parse_edn_dict(s)
  local res = {}
  if not s or s == "" then return res end
  for k, v in s:gmatch('"([^"]+)"%s+(%a+)') do
    if v == "true" or v == "false" then res[k] = (v == "true") end
  end
  return res
end

function M.serialize_edn_dict(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys)
  local parts = vim.iter(keys):map(function(k) return string.format('"%s" %s', k, t[k] and "true" or "false") end):totable()
  return "{" .. table.concat(parts, ", ") .. "}"
end

function M.make_progress_bar(current, total, width)
  width = width or 20
  local ratio = total > 0 and (current / total) or 1
  local filled = math.floor(ratio * width)
  return string.format("[%s%s] %d%%", string.rep("█", filled), string.rep(" ", width - filled), math.floor(ratio * 100))
end

return M
