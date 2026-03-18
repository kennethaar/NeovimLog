local config = require("logseq.config")
local M = {}

-- Hjelpefunksjoner for stihåndtering
local function normalize(p)
  local resolved = vim.fn.resolve(vim.fn.expand(p)):gsub("\\", "/")
  if vim.fn.has("win32") == 1 then resolved = resolved:lower() end
  return resolved
end

local function is_vault_file(bufpath)
  local vault = config.current.vault_norm
  if not vault or vault == "" then return false end
  return normalize(bufpath):sub(1, #vault) == vault
end

-- Globale funksjoner for UI-elementer
_G._logseq_winbar = function()
  local filepath = vim.api.nvim_buf_get_name(0)
  local name = vim.fn.fnamemodify(filepath, ":t")
  if name == "" then return "" end
  local title = name:gsub("%.md$", ""):gsub("---", "/")
  return " " .. title
end

_G._logseq_open_help = function()
  -- Forsøker å finne README eller hjelpefil i samme mappe som denne lua-fila
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local current_dir = vim.fn.fnamemodify(src, ":p:h")
  local help_file = current_dir .. "/README.md" 
  if vim.fn.filereadable(help_file) == 1 then
    vim.cmd("vsplit " .. vim.fn.fnameescape(help_file))
  else
    print("Logseq-modus aktiv. Bruk ,l for lenker, za for folding.")
  end
end

-- Aktiveringsfunksjon for Logseq-filer
local function activate(bufnr)
  if vim.b[bufnr].logseq_active then return end
  vim.b[bufnr].logseq_active = true

  -- Last inn de andre modulene dine (VIKTIG!)
  -- Disse filene må ligge i lua/logseq/ mappen din
  pcall(function()
    require("logseq.fold").setup_buf()
    require("logseq.motions").setup_buf()
    require("logseq.links").setup_buf()
    if config.current.enable_link_search then
      require("logseq.page_search").setup_buf(bufnr)
    end
  end)

  -- =========================================================
  -- NYTT: Skjul Logseq UID (Conceal)
  -- =========================================================
  -- Setter conceal-nivå til 2 (som betyr "skjul teksten helt")
  vim.opt_local.conceallevel = 2
  -- Kjører en syntax-regel som finner "id::" og skjuler hele linjen
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd([[syntax match LogseqUID /^\s*id::.*$/ conceal]])
  end)
  -- =========================================================

  -- UI: Winbar og Statusline
  vim.opt_local.winbar = "%!v:lua._logseq_winbar()"
  local stl = vim.o.statusline
  if stl == "" then stl = "%<%f %h%m%r%=%-14.(%l,%c%V%) %P" end
  if not stl:match("_logseq_open_help") then
    vim.opt_local.statusline = stl .. " %=%@v:lua._logseq_open_help@ hh %X"
  end

  -- Hurtigtaster og innstillinger
  vim.keymap.set("n", "hh", _G._logseq_open_help, { buffer = bufnr, desc = "Logseq Hjelp" })
  
-- =========================================================
  -- OPPDATERT: Logseq Smart Insert (Håndterer skjulte properties)
  -- =========================================================
  -- Smart Bullet: Enter
  vim.keymap.set("i", "<CR>", function()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local indent = line:match("^(%s*)") or ""
    local is_at_end = (col >= #line)
    
    -- 1. Hvis markøren er PÅ id:: linjen
    if line:match("id::") then
      local parent_indent = indent:sub(1, -3) 
      return "<CR>" .. parent_indent .. "- "
    end
    
    -- 2. Hvis vi står på slutten av møtetittelen og id:: ligger usynlig rett under
    local buf = vim.api.nvim_get_current_buf()
    local next_line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    if is_at_end and next_line:match("^%s+id::") then
      return "<Down><End><CR>" .. indent .. "- "
    end
    
    -- 3. Standard oppførsel
    return "<CR>" .. indent .. "- "
  end, { buffer = bufnr, expr = true, desc = "Logseq Smart Bullet" })

  -- Smart Property: Shift+Enter
  vim.keymap.set("i", "<S-CR>", function()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local indent = line:match("^(%s*)") or ""
    local is_at_end = (col >= #line)
    
    -- 1. Hvis vi er PÅ id:: linjen
    if line:match("id::") then
      return "<CR>" .. indent
    end
    
    -- 2. Hvis vi står på møtetittelen og vil ha notater UNDER id-en
    local buf = vim.api.nvim_get_current_buf()
    local next_line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    if is_at_end and line:match("^%s*%- ") and next_line:match("^%s+id::") then
      return "<Down><End><CR>" .. indent .. "  "
    end
    
    -- 3. Standard oppførsel
    if line:match("^%s*%- ") then indent = indent .. "  " end
    return "<CR>" .. indent
  end, { buffer = bufnr, expr = true, desc = "Logseq Smart Property" })

  -- Logseq Indentering med Tab
  vim.keymap.set("i", "<Tab>", "<C-t>", { buffer = bufnr, desc = "Logseq Indent" })
  vim.keymap.set("i", "<S-Tab>", "<C-d>", { buffer = bufnr, desc = "Logseq Outdent" })
  vim.keymap.set("n", "<Tab>", ">>", { buffer = bufnr, desc = "Logseq Indent Normal" })
  vim.keymap.set("n", "<S-Tab>", "<<", { buffer = bufnr, desc = "Logseq Outdent Normal" })
 
-- =========================================================
  -- TODO State Cycling: Ctrl+T (Normal + Insert)
  -- =========================================================
  local todo_states = { "TODO", "WAITING", "DOING", "DONE", "CANCELLED" }

  local function cycle_todo()
    local parser = require("logseq.parser")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local parsed = parser.parse(lines)
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local block = parser.block_at_line(parsed.blocks, lnum)
    if not block then return end

    local line = lines[block.line_start]
    local indent, rest = line:match("^(%s*)%- (.*)$")
    if not indent then return end

    -- Find current state
    local current_state = nil
    local content_after = rest
    for _, state in ipairs(todo_states) do
      local after = rest:match("^" .. state .. "%s*(.*)")
      if after then
        current_state = state
        content_after = after
        break
      end
    end

    -- Determine next state
    local next_state = nil
    if current_state then
      for i, state in ipairs(todo_states) do
        if state == current_state then
          next_state = todo_states[i + 1] -- nil if last → removes state
          break
        end
      end
    else
      next_state = todo_states[1] -- no state → TODO
    end

    -- Build new line
    local new_line
    if next_state then
      new_line = indent .. "- " .. next_state .. " " .. content_after
    else
      new_line = indent .. "- " .. content_after
    end

    vim.api.nvim_buf_set_lines(0, block.line_start - 1, block.line_start, false, { new_line })
  end

  vim.keymap.set("n", "<C-t>", cycle_todo, { buffer = bufnr, desc = "Logseq: cycle TODO state" })
  vim.keymap.set("i", "<C-t>", function()
    cycle_todo()
    vim.cmd("startinsert!")
  end, { buffer = bufnr, desc = "Logseq: cycle TODO state (insert)" })
  -- =========================================================

  -- Logseq-vennlige tabulator-innstillinger
  vim.opt_local.shiftwidth = 2
  vim.opt_local.tabstop = 2
  vim.opt_local.expandtab = true
  vim.opt_local.softtabstop = 2
end

-- Hoved-setup
function M.setup(opts)
  if not config.setup(opts) then return end
  config.current.vault_norm = normalize(config.current.vault_path)

  local group = vim.api.nvim_create_augroup("logseq_nvim", { clear = true })
  
  -- =========================================================
  -- NYTT: Manuell kalenderkommando
  -- =========================================================
  vim.api.nvim_create_user_command("Calsync", function()
    require("calendar").sync() -- Pass på at modulen heter "calendar" (ev. "logseq.calendar")
  end, {})

  -- Automatisk aktivering når du åpner en .md-fil i vaulten
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if is_vault_file(vim.api.nvim_buf_get_name(ev.buf)) then 
        activate(ev.buf) 
        -- =========================================================
        -- NYTT: Auto-sync kalender når filen åpnes
        -- =========================================================
        pcall(function() require("calendar").sync() end) 
      end
    end,
  })

  -- Kommando for å hoppe til dagens journal
  vim.api.nvim_create_user_command("LogseqToday", function()
    local vault = config.current.vault_path
    local dir = vault .. "/journals"
    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
    local filename = os.date(config.current.journal_format) .. ".md"
    local filepath = dir .. "/" .. filename
    
    -- Hvis vi allerede er i fila, ikke gjør noe
    if normalize(vim.api.nvim_buf_get_name(0)) == normalize(filepath) then return end
    
    -- Lagre nåværende fil før vi bytter
    if vim.bo.modified then vim.cmd("write") end
    
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    -- Liten forsinkelse for å sikre at alt lastes riktig
    vim.defer_fn(function() activate(vim.api.nvim_get_current_buf()) end, 50)
  end, {})
end

return M