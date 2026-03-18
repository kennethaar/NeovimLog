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
  end)

  -- UI: Winbar og Statusline
  vim.opt_local.winbar = "%!v:lua._logseq_winbar()"
  local stl = vim.o.statusline
  if stl == "" then stl = "%<%f %h%m%r%=%-14.(%l,%c%V%) %P" end
  if not stl:match("_logseq_open_help") then
    vim.opt_local.statusline = stl .. " %=%@v:lua._logseq_open_help@ hh %X"
  end

  -- Hurtigtaster og innstillinger
  vim.keymap.set("n", "hh", _G._logseq_open_help, { buffer = bufnr, desc = "Logseq Hjelp" })
  
  -- Autolagring (skjer kun når du går ut av Insert-modus eller endrer tekst)
  vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
    buffer = bufnr,
    callback = function()
      if vim.bo.modified then vim.cmd("silent! write") end
    end,
  })

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
  
  -- Automatisk aktivering når du åpner en .md-fil i vaulten
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if is_vault_file(vim.api.nvim_buf_get_name(ev.buf)) then 
        activate(ev.buf) 
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