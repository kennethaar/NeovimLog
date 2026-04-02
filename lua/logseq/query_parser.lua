--- logseq.nvim query parser
--- Parses Logseq simple query syntax into an AST.
---
--- Supported predicates:
---   [[page]]                   page-link atom
---   (and EXPR...)              boolean and
---   (or  EXPR...)              boolean or
---   (not EXPR)                 boolean not
---   (todo STATE...)            TODO state filter
---   (tags TAG...)              tag filter
---   (property KEY [VAL])       block property filter
---   (page-property KEY [VAL])  page-level property filter
---   (between <DATE> <DATE>)    journal date range

local M = {}

-- ── Tokenizer ─────────────────────────────────────────────────────────

---@param s string
---@return table[]|nil tokens
---@return string|nil  error
local function tokenize(s)
  local tokens = {}
  local i = 1

  while i <= #s do
    local c = s:sub(i, i)

    if c:match("%s") then
      i = i + 1

    elseif c == "(" then
      tokens[#tokens + 1] = { type = "lparen" }
      i = i + 1

    elseif c == ")" then
      tokens[#tokens + 1] = { type = "rparen" }
      i = i + 1

    elseif s:sub(i, i + 1) == "[[" then
      local j = s:find("%]%]", i + 2)
      if not j then return nil, "unclosed [[" end
      tokens[#tokens + 1] = { type = "page", value = s:sub(i + 2, j - 1) }
      i = j + 2

    elseif c == "<" then
      local j = s:find(">", i + 1, true)
      if not j then return nil, "unclosed <" end
      local inner = s:sub(i + 1, j - 1)
      local date  = inner:match("^(%d%d%d%d%-%d%d%-%d%d)")
      tokens[#tokens + 1] = { type = "date", value = date or inner }
      i = j + 1

    elseif c == '"' then
      local j = s:find('"', i + 1, true)
      if not j then return nil, "unclosed string" end
      tokens[#tokens + 1] = { type = "word", value = s:sub(i + 1, j - 1) }
      i = j + 1

    else
      local word = s:match("^([^%s%(%)%[%]<>\"]+)", i)
      if word then
        tokens[#tokens + 1] = { type = "word", value = word }
        i = i + #word
      else
        i = i + 1
      end
    end
  end

  return tokens, nil
end

-- ── Predicate parsers (table-dispatched) ──────────────────────────────

local parse_expr  -- forward declaration

-- Collect EXPR* until rparen; advance past rparen.
local function collect_children(tokens, pos)
  local children = {}
  while tokens[pos] and tokens[pos].type ~= "rparen" do
    local child, new_pos, err = parse_expr(tokens, pos)
    if err then return nil, new_pos, err end
    children[#children + 1] = child
    pos = new_pos
  end
  return children, (tokens[pos] and pos + 1 or pos), nil
end

-- Advance past optional rparen.
local function skip_rparen(tokens, pos)
  if tokens[pos] and tokens[pos].type == "rparen" then return pos + 1 end
  return pos
end

-- Collect WORD* tokens (stopping at rparen or end).
local function collect_words(tokens, pos)
  local words = {}
  while tokens[pos] and tokens[pos].type == "word" do
    words[#words + 1] = tokens[pos].value
    pos = pos + 1
  end
  return words, skip_rparen(tokens, pos)
end

-- Parse a key + optional value (word or [[page]]), then skip rparen.
local function parse_kv(tokens, pos, node_type)
  local key_tok = tokens[pos]
  if not key_tok or key_tok.type ~= "word" then
    return nil, pos, node_type .. " requires a key"
  end
  pos = pos + 1

  local value
  local val_tok = tokens[pos]
  if val_tok and val_tok.type == "word" then
    value = val_tok.value
    pos   = pos + 1
  elseif val_tok and val_tok.type == "page" then
    value = "[[" .. val_tok.value .. "]]"
    pos   = pos + 1
  end

  return { type = node_type, key = key_tok.value, value = value },
         skip_rparen(tokens, pos), nil
end

local predicate_parsers = {}

predicate_parsers["and"] = function(tokens, pos)
  local children, new_pos, err = collect_children(tokens, pos)
  if err then return nil, new_pos, err end
  return { type = "and", children = children }, new_pos, nil
end

predicate_parsers["or"] = function(tokens, pos)
  local children, new_pos, err = collect_children(tokens, pos)
  if err then return nil, new_pos, err end
  return { type = "or", children = children }, new_pos, nil
end

predicate_parsers["not"] = function(tokens, pos)
  local child, new_pos, err = parse_expr(tokens, pos)
  if err then return nil, new_pos, err end
  return { type = "not", children = { child } }, skip_rparen(tokens, new_pos), nil
end

predicate_parsers["todo"] = function(tokens, pos)
  local words, new_pos = collect_words(tokens, pos)
  local states = {}
  for _, w in ipairs(words) do states[#states + 1] = w:upper() end
  return { type = "todo", states = states }, new_pos, nil
end

predicate_parsers["tags"] = function(tokens, pos)
  local words, new_pos = collect_words(tokens, pos)
  return { type = "tags", tags = words }, new_pos, nil
end

predicate_parsers["property"] = function(tokens, pos)
  return parse_kv(tokens, pos, "property")
end

predicate_parsers["page-property"] = function(tokens, pos)
  return parse_kv(tokens, pos, "page_property")
end

predicate_parsers["between"] = function(tokens, pos)
  local from_tok = tokens[pos]
  if not from_tok then return nil, pos, "between requires two dates" end
  local from = from_tok.value
  pos = pos + 1

  local to_tok = tokens[pos]
  if not to_tok then return nil, pos, "between requires two dates" end
  local to = to_tok.value
  pos = pos + 1

  return { type = "between", from = from, to = to }, skip_rparen(tokens, pos), nil
end

local function parse_list(tokens, pos)
  local sym_tok = tokens[pos]
  if not sym_tok or sym_tok.type ~= "word" then
    return nil, pos, "expected symbol after ("
  end

  local sym    = sym_tok.value:lower()
  local parser = predicate_parsers[sym]

  if not parser then
    -- Unknown predicate: skip to closing rparen and return stub.
    local skip = pos + 1
    while tokens[skip] and tokens[skip].type ~= "rparen" do skip = skip + 1 end
    return { type = "unknown", sym = sym }, skip_rparen(tokens, skip), nil
  end

  return parser(tokens, pos + 1)
end

parse_expr = function(tokens, pos)
  local tok = tokens[pos]
  if not tok                 then return nil, pos, "unexpected end of input" end
  if tok.type == "lparen"    then return parse_list(tokens, pos + 1) end
  if tok.type == "page"      then return { type = "page_link", page = tok.value }, pos + 1, nil end
  if tok.type == "word"      then return { type = "word", value = tok.value },     pos + 1, nil end
  if tok.type == "date"      then return { type = "word", value = tok.value },     pos + 1, nil end
  return nil, pos, "unexpected token type: " .. tok.type
end

-- ── Public API ─────────────────────────────────────────────────────────

--- Extract the inner query expression from a {{query EXPR}} line.
--- Returns nil if the line does not contain a query block.
---@param line string
---@return string|nil
function M.extract(line)
  local inner = line:match("{%{query%s+(.-)}%}") or line:match("{%{query%s+(.+)")
  if inner then return inner:match("^%s*(.-)%s*$") end
end

--- Parse a Logseq simple query expression string into an AST.
---@param query_str string
---@return table|nil  ast
---@return string|nil error
function M.parse(query_str)
  if not query_str or query_str:match("^%s*$") then return nil, "empty query" end
  local tokens, err = tokenize(query_str)
  if err then return nil, err end
  if #tokens == 0 then return nil, "empty query" end
  local ast, _, parse_err = parse_expr(tokens, 1)
  return ast, parse_err
end

--- Serialise an AST node back to a Logseq query expression string.
---@param ast table
---@return string
function M.to_string(ast)
  if not ast then return "" end

  local serializers = {
    page_link     = function(n) return "[[" .. n.page .. "]]" end,
    todo          = function(n) return "(todo " .. table.concat(n.states or {}, " ") .. ")" end,
    tags          = function(n) return "(tags " .. table.concat(n.tags  or {}, " ") .. ")" end,
    between       = function(n) return "(between <" .. n.from .. "> <" .. n.to .. ">)" end,
    property      = function(n)
      return "(property " .. n.key .. (n.value and (" " .. n.value) or "") .. ")"
    end,
    page_property = function(n)
      return "(page-property " .. n.key .. (n.value and (" " .. n.value) or "") .. ")"
    end,
    ["and"] = function(n)
      local parts = {}
      for _, c in ipairs(n.children or {}) do parts[#parts + 1] = M.to_string(c) end
      return "(and " .. table.concat(parts, " ") .. ")"
    end,
    ["or"]  = function(n)
      local parts = {}
      for _, c in ipairs(n.children or {}) do parts[#parts + 1] = M.to_string(c) end
      return "(or " .. table.concat(parts, " ") .. ")"
    end,
    ["not"] = function(n)
      return "(not " .. M.to_string((n.children or {})[1]) .. ")"
    end,
  }

  local fn = serializers[ast.type]
  return fn and fn(ast) or ""
end

return M
