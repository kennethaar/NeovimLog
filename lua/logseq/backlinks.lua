--- logseq.nvim backlinks (Linked References)
local config  = require("logseq.config")
local indexer = require("logseq.indexer")
local util    = require("logseq.util")

local M = {}

-- ── Constants & Global State ──────────────────────────────────────────
local SECTION_HDR_PAT = "^── %d+ .-──$"
local LOADING_PAT     = "^── Loading Linked References"
local FILTER_HDR      = "── Filters ──"
local SEPARATOR = ""
local NS = vim.api.nvim_create_namespace("logseq_backlinks")

-- RUNBOOK: Single global augroup to prevent memory leaks
local global_augroup = vim.api.nvim_create_augroup("LogseqBacklinks", { clear = false })

-- RUNBOOK: High-performance libuv timer pool for debouncing
local timers = {}
local function debounce(bufnr, delay, fn)
  if not timers[bufnr] then timers[bufnr] = vim.uv.new_timer() end
  timers[bufnr]:stop()
  timers[bufnr]:start(delay, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(bufnr) then fn(bufnr) end
  end))
end

-- ── Helpers ───────────────────────────────────────────────────────────
local function with_modifiable(bufnr, fn)
  local was_modified   = vim.bo[bufnr].modified
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  fn()
  vim.bo[bufnr].modified   = was_modified
  vim.bo[bufnr].modifiable = was_modifiable
end

local function find_section_start(bufnr, header_line)
  if header_line <= 1 then return header_line end
  local line = vim.api.nvim_buf_get_lines(bufnr, header_line - 2, header_line - 1, false)[1]
  if line and line:match("^%s*$") then return header_line - 1 end
  return header_line
end

-- ── State ────────────────────────────────────────────────────────────
M._state = {} -- bufnr → { visible, region, source_map, had_backlinks, ... }

local function get_state(bufnr)
  if not M._state[bufnr] then
    M._state[bufnr] = {
      visible       = false,
      region        = nil,
      source_map    = nil,
      had_backlinks = false,
      filter        = {},
      filter_items  = {},
      cached_results    = nil,
      cached_scheduled  = nil,
    }
  end
  return M._state[bufnr]
end

local function get_page_name(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return nil end
  local basename = vim.fn.fnamemodify(filepath, ":t")
  local vault = config.current.vault_path
  local journal_name = util.format_journal_date(basename, vault)
  if journal_name then return journal_name end
  return util.decode_filename(basename)
end

function M.in_region(bufnr, lnum)
  local state = get_state(bufnr)
  if not state.region then return false end
  return lnum >= state.region.start_line and lnum <= state.region.end_line
end

local function find_header_line(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local topmost = nil
  for i = #lines, 1, -1 do
    local line = lines[i]
    if line:match(SECTION_HDR_PAT) or line:match(LOADING_PAT) or line == FILTER_HDR then
      topmost = i
    elseif topmost and line == "" then
      break
    end
  end
  return topmost
end

local function recalculate_region(bufnr)
  local state = get_state(bufnr)
  if not state.visible or not state.region then return end
  local header_line = find_header_line(bufnr)
  if not header_line then
    state.visible, state.region, state.source_map = false, nil, nil
    return
  end
  local new_start = find_section_start(bufnr, header_line)
  local new_end = vim.api.nvim_buf_line_count(bufnr)
  local shift = new_start - state.region.start_line
  if shift == 0 then
    state.region.end_line = new_end
    return
  end
  local new_smap = {}
  for abs_line, info in pairs(state.source_map or {}) do
    new_smap[abs_line + shift] = info
  end
  state.region = { start_line = new_start, end_line = new_end }
  state.source_map = new_smap
end

-- ── Filtering ────────────────────────────────────────────────────────

local function read_page_filters(filepath)
  local f = io.open(filepath, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local edn_str = content:match("^filters::%s*([^\n]+)") or content:match("\nfilters::%s*([^\n]+)")
  return edn_str and util.parse_edn_dict(edn_str:match("^%s*(.-)%s*$")) or {}
end

local function write_page_filters(bufnr, filepath, filter)
  local edn = util.serialize_edn_dict(filter)
  local new_line = "filters:: " .. edn
  local f = io.open(filepath, "r")
  if not f then return end
  local disk_content = f:read("*a")
  f:close()
  local new_content = disk_content:find("filters::", 1, true) and disk_content:gsub("filters::[^\n]*", new_line) or (new_line .. "\n" .. disk_content)
  local f2 = io.open(filepath, "w")
  if f2 then f2:write(new_content) f2:close() end
  if type(indexer.invalidate) == "function" then indexer.invalidate(filepath) end
  local state = get_state(bufnr)
  local region_start = state.region and state.region.start_line or math.huge
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local updated = false
  for i, line in ipairs(buf_lines) do
    if i >= region_start then break end
    if line:match("^filters::") then
      with_modifiable(bufnr, function() vim.api.nvim_buf_set_lines(bufnr, i-1, i, false, {new_line}) end)
      updated = true break
    end
  end
  if not updated then with_modifiable(bufnr, function() vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, {new_line}) end) end
end

local function collect_filter_items(results, scheduled_data)
  local items = {}
  if scheduled_data then
    if #(scheduled_data.overdue or {}) > 0 then table.insert(items, "overdue") end
    if #(scheduled_data.upcoming or {}) > 0 then table.insert(items, "scheduled") end
  end
  local todo_set, tag_set = {}, {}
  local function collect_from(list)
    for _, r in ipairs(list or {}) do
      if r.todo_state then todo_set[r.todo_state] = true end
      for _, tag in ipairs(r.tags or {}) do tag_set["#" .. tag] = true end
    end
  end
  collect_from(results)
  if scheduled_data then collect_from(scheduled_data.overdue) collect_from(scheduled_data.upcoming) end
  for _, s in ipairs(util.todo_states) do if todo_set[s] then table.insert(items, s) end end
  local tags = {}
  for tag in pairs(tag_set) do table.insert(tags, tag) end
  table.sort(tags)
  vim.list_extend(items, tags)
  return items
end

local function filter_scheduled(scheduled_data, filter)
  if not scheduled_data or not filter or not next(filter) then return scheduled_data end
  local has_inc, has_exc = false, false
  for k, v in pairs(filter) do
    if k ~= "very_next_actions" and k ~= "overdue" and k ~= "scheduled" then
      if v == true then has_inc = true elseif v == false then has_exc = true end
    end
  end
  local vna = filter["very_next_actions"]
  local function keep(e)
    if vna == true and (not e.todo_state or e.has_todo_children) then return false end
    if vna == false and (e.todo_state and not e.has_todo_children) then return false end
    if has_exc then
      if e.todo_state and filter[e.todo_state] == false then return false end
      for _, t in ipairs(e.tags or {}) do if filter["#"..t] == false then return false end end
    end
    if has_inc then
      if e.todo_state and filter[e.todo_state] == true then return true end
      for _, t in ipairs(e.tags or {}) do if filter["#"..t] == true then return true end end
      return false
    end
    return true
  end
  return { overdue = vim.tbl_filter(keep, scheduled_data.overdue or {}), upcoming = vim.tbl_filter(keep, scheduled_data.upcoming or {}) }
end

local function apply_filters(results, filter)
  if not filter or not next(filter) then return results end
  local vna = filter["very_next_actions"] == true
  local has_inc, has_exc = false, false
  for k, v in pairs(filter) do if k ~= "very_next_actions" then if v == true then has_inc = true elseif v == false then has_exc = true end end end
  return vim.tbl_filter(function(r)
    if vna and (not r.todo_state or r.has_todo_children) then return false end
    if filter["very_next_actions"] == false and (r.todo_state and not r.has_todo_children) then return false end
    if has_exc then
      if r.todo_state and filter[r.todo_state] == false then return false end
      for _, t in ipairs(r.tags or {}) do if filter["#"..t] == false then return false end end
    end
    if has_inc then
      if r.todo_state and filter[r.todo_state] == true then return true end
      for _, t in ipairs(r.tags or {}) do if filter["#"..t] == true then return true end end
      return false
    end
    return true
  end, results or {})
end

-- ── Display Builder ──────────────────────────────────────────────────

local function append_sched_section(label, hl_group, entries, display, smap, hl_lines)
  if not entries or #entries == 0 then return end
  table.insert(display, string.format("── %d %s ──", #entries, label))
  table.insert(hl_lines, { #display, hl_group, 0, -1 })
  local groups, order = {}, {}
  for _, e in ipairs(entries) do
    if not groups[e.source_page] then groups[e.source_page] = { file = e.source_file, items = {} } table.insert(order, e.source_page) end
    table.insert(groups[e.source_page].items, e)
  end
  for _, page in ipairs(order) do
    local g = groups[page]
    local cnt = 0
    for _, e in ipairs(g.items) do for _, cb in ipairs(e.context_blocks or {}) do if not cb.is_ancestor then cnt = cnt + 1 end end end
    table.insert(display, string.format("- [[%s]]  ⋯ %d %s", page, cnt, cnt == 1 and "line" or "lines"))
    smap[#display] = { file = g.file, line = 1 }
    for _, e in ipairs(g.items) do
      for _, cb in ipairs(e.context_blocks or {}) do
        local prefix = cb.is_ancestor and "▸ " or "- "
        table.insert(display, string.rep(" ", cb.indent or 0) .. prefix .. (cb.text or ""))
        smap[#display] = { file = e.source_file, line = cb.source_line }
      end
    end
  end
end

local function build_display(results, scheduled_data, filter, filter_items)
  local display, smap, match_lines, hl_lines = {}, {}, {}, {}
  local all_f = { "very_next_actions" }
  vim.list_extend(all_f, filter_items or {})
  table.insert(display, FILTER_HDR)
  table.insert(hl_lines, { #display, "Title", 0, -1 })
  for _, item in ipairs(all_f) do
    local v = filter and filter[item]
    local ind = v == true and "[+]" or v == false and "[-]" or "[ ]"
    local hl = v == true and "LogseqLink" or v == false and "DiagnosticError" or "Comment"
    local lbl = item == "very_next_actions" and "Very Next Actions" or item == "overdue" and "Overdue" or item == "scheduled" and "Scheduled" or item
    table.insert(display, string.format("  %s  %s", ind, lbl))
    smap[#display] = { action = "filter", item = item }
    table.insert(hl_lines, { #display, hl, 2, 5 })
  end
  if scheduled_data then
    if not filter or filter["overdue"] ~= false then append_sched_section("Overdue", "DiagnosticError", scheduled_data.overdue, display, smap, hl_lines) end
    if not filter or filter["scheduled"] ~= false then append_sched_section("Scheduled", "LogseqScheduled", scheduled_data.upcoming, display, smap, hl_lines) end
  end
  local total = 0
  for _, r in ipairs(results or {}) do for _, cb in ipairs(r.context_blocks or {}) do if cb.is_match then total = total + 1 end end end
  table.insert(display, string.format("── %d Linked %s ──", total, total == 1 and "Reference" or "References"))
  table.insert(hl_lines, { #display, "Title", 0, -1 })
  local groups, order = {}, {}
  for _, r in ipairs(results or {}) do
    if not groups[r.source_page] then groups[r.source_page] = { file = r.source_file, entries = {} } table.insert(order, r.source_page) end
    table.insert(groups[r.source_page].entries, r)
  end
  for _, page in ipairs(order) do
    local g = groups[page]
    local l_cnt = 0
    for _, e in ipairs(g.entries) do for _, cb in ipairs(e.context_blocks or {}) do if not cb.is_ancestor then l_cnt = l_cnt + 1 end end end
    table.insert(display, string.format("- [[%s]]  ⋯ %d %s", page, l_cnt, l_cnt == 1 and "line" or "lines"))
    smap[#display] = { file = g.file, line = 1 }
    for _, e in ipairs(g.entries) do
      for _, cb in ipairs(e.context_blocks or {}) do
        table.insert(display, string.rep(" ", cb.indent or 0) .. (cb.is_ancestor and "▸ " or "- ") .. (cb.text or ""))
        smap[#display] = { file = e.source_file, line = cb.source_line }
        if cb.is_match then match_lines[#display] = true end
      end
    end
  end
  return display, smap, match_lines, hl_lines
end

-- ── Render Engine ────────────────────────────────────────────────────

local function apply_and_render(bufnr)
  local state = get_state(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not state.cached_results then return end
  local res = apply_filters(state.cached_results, state.filter)
  local sched = filter_scheduled(state.cached_scheduled, state.filter)
  M.remove_section(bufnr)
  local lines, smap, m_lines, hls = build_display(res, sched, state.filter, state.filter_items)
  local start = vim.api.nvim_buf_line_count(bufnr) + 1
  with_modifiable(bufnr, function() vim.api.nvim_buf_set_lines(bufnr, start-1, start-1, false, { SEPARATOR, unpack(lines) }) end)
  state.region = { start_line = start, end_line = start + #lines }
  state.visible, state.source_map = true, {}
  for rel, info in pairs(smap) do
    local abs = start + rel
    state.source_map[abs] = info
    if m_lines[rel] then vim.api.nvim_buf_add_highlight(bufnr, NS, "Bold", abs-1, 0, -1) end
  end
  for _, hl in ipairs(hls) do vim.api.nvim_buf_add_highlight(bufnr, NS, hl[2], start + hl[1] - 1, hl[3], hl[4]) end
  for abs, info in pairs(state.source_map) do
    if not info.action then
      local txt = vim.api.nvim_buf_get_lines(bufnr, abs-1, abs, false)[1] or ""
      if txt:match("^%- %[%[.+%]%]%s+⋯") then vim.api.nvim_buf_add_highlight(bufnr, NS, "LogseqLink", abs-1, 0, -1) end
    end
  end
end

function M.render_section(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local basename = vim.fn.fnamemodify(filepath, ":t")
  local page_name = get_page_name(bufnr)
  if not page_name then return end

  -- Extract ISO alias for journal pages
  local y, m, d = basename:match("^(%d%d%d%d)[_%-](%d%d)[_%-](%d%d)%.md$")
  local iso_date = y and string.format("%s-%s-%s", y, m, d) or nil

  local state = get_state(bufnr)
  if not next(state.filter) then state.filter = read_page_filters(filepath) end
  local vault = config.current.vault_path or ""
  local is_j = util.normalize(vault.."/journals") ~= "" and vim.startswith(util.normalize(filepath), util.normalize(vault.."/journals").."/")
  
  local start = vim.api.nvim_buf_line_count(bufnr) + 1
  with_modifiable(bufnr, function() vim.api.nvim_buf_set_lines(bufnr, start-1, start-1, false, { SEPARATOR, "── Loading Linked References... "..util.make_progress_bar(0, 100, 20).." ──" }) end)
  state.region, state.visible = { start_line = start, end_line = start + 1 }, true
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  vim.cmd("redraw")

  local token = {}
  state._render_token = token
  local pending = is_j and 2 or 1
  local b_res, s_data = nil, nil

  local function do_render()
    if state._render_token ~= token or not vim.api.nvim_buf_is_valid(bufnr) then return end
    state.cached_results, state.cached_scheduled = b_res or {}, s_data
    state.filter_items = collect_filter_items(state.cached_results, state.cached_scheduled)
    apply_and_render(bufnr)
  end

  -- RUNBOOK: Wrap the callbacks in vim.schedule_wrap to prevent "fast event context" (E5560) errors
  indexer.find_backlinks(page_name, filepath, 
    vim.schedule_wrap(function(r) 
      b_res = r 
      pending = pending - 1 
      if pending == 0 then do_render() end 
    end), 
    vim.schedule_wrap(function(curr, tot)
      if not vim.api.nvim_buf_is_valid(bufnr) or not state.visible or not state.region then return end
      with_modifiable(bufnr, function() pcall(vim.api.nvim_buf_set_lines, bufnr, state.region.start_line, state.region.start_line+1, false, { "── Loading Linked References... "..util.make_progress_bar(curr, tot, 20).." ──" }) end)
      vim.cmd("redraw")
    end), 
    iso_date
  )

  if is_j then 
    indexer.find_scheduled_blocks(os.date("%Y-%m-%d"), 
      vim.schedule_wrap(function(d) 
        s_data = d 
        pending = pending - 1 
        if pending == 0 then do_render() end 
      end)
    ) 
  end
end

function M.remove_section(bufnr)
  local state = get_state(bufnr)
  state._render_token = nil
  local hdr = find_header_line(bufnr)
  if not hdr then state.visible, state.region, state.source_map = false, nil, nil return false end
  local start = find_section_start(bufnr, hdr)
  with_modifiable(bufnr, function() vim.api.nvim_buf_set_lines(bufnr, start-1, -1, false, {}) end)
  state.visible, state.region, state.source_map = false, nil, nil
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  return true
end

function M.toggle()
  local b = vim.api.nvim_get_current_buf()
  if get_state(b).visible then M.remove_section(b) else M.render_section(b) end
end

function M.navigate()
  local b, l = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1]
  if not M.in_region(b, l) then return false end
  local target = get_state(b).source_map[l]
  if not target then return false end
  if target.action == "filter" then
    local s = get_state(b)
    s.filter[target.item] = s.filter[target.item] == nil and true or (s.filter[target.item] == true and false or nil)
    write_page_filters(b, vim.api.nvim_buf_get_name(b), s.filter)
    apply_and_render(b)
    for abs, info in pairs(get_state(b).source_map) do if info.item == target.item then pcall(vim.api.nvim_win_set_cursor, 0, {abs, 2}) break end end
    return true
  end
  vim.cmd("normal! m'")
  vim.cmd.edit(vim.fn.fnameescape(target.file))
  if target.line then pcall(vim.api.nvim_win_set_cursor, 0, {target.line, 0}) end
  return true
end

function M.setup_buf(bufnr)
  local toggle_key = (config.current.keymaps or {}).toggle_backlinks or "<leader>b"
  vim.keymap.set("n", toggle_key, M.toggle, { buffer = bufnr, silent = true })

  -- RUNBOOK: Attach to the single global augroup with buffer = bufnr
  vim.api.nvim_create_autocmd("BufWritePre", { 
    group = global_augroup, 
    buffer = bufnr, 
    callback = function() 
      get_state(bufnr).had_backlinks = get_state(bufnr).visible 
      M.remove_section(bufnr) 
    end 
  })

  vim.api.nvim_create_autocmd("BufWritePost", { 
    group = global_augroup, 
    buffer = bufnr, 
    callback = function() 
      if vim.api.nvim_buf_get_name(bufnr) ~= "" and indexer.invalidate then 
        indexer.invalidate(vim.api.nvim_buf_get_name(bufnr)) 
      end
      if get_state(bufnr).had_backlinks then 
        vim.schedule(function() 
          if get_state(bufnr).cached_results then apply_and_render(bufnr) else M.render_section(bufnr) end 
        end) 
      end
    end 
  })

  vim.api.nvim_create_autocmd("InsertEnter", { 
    group = global_augroup, 
    buffer = bufnr, 
    callback = function() 
      if M.in_region(bufnr, vim.api.nvim_win_get_cursor(0)[1]) then 
        vim.cmd("stopinsert") 
        vim.notify("[logseq.nvim] Backlinks are read-only.") 
      end 
    end 
  })

  -- RUNBOOK: High-Performance Debouncing for TextChanged events
  vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, { 
    group = global_augroup, 
    buffer = bufnr, 
    callback = function() 
      if get_state(bufnr).visible then 
        debounce(bufnr, 150, recalculate_region) 
      end 
    end 
  })

  -- RUNBOOK: Cleanup to prevent C-level memory leaks
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = global_augroup, 
    buffer = bufnr,
    callback = function()
      if timers[bufnr] then
        timers[bufnr]:stop()
        if not timers[bufnr]:is_closing() then timers[bufnr]:close() end
        timers[bufnr] = nil
      end
    end,
  })
end

function M.setup_global()
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = global_augroup, -- RUNBOOK: Share the global group
    pattern = "*.md",
    callback = function(ev)
      if not util.is_vault_file(ev.file, config.current.vault_path) then return end
      for bufnr, state in pairs(M._state) do
        if bufnr ~= ev.buf and state.visible and vim.api.nvim_buf_is_valid(bufnr) then
          vim.schedule(function() 
            if vim.api.nvim_buf_is_valid(bufnr) then 
              M.remove_section(bufnr) 
              M.render_section(bufnr) 
            end 
          end)
        end
      end
    end,
  })
end

return M