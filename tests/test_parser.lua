#!/usr/bin/env lua5.4
--- Test suite for logseq.nvim parser (runs outside Neovim)
--- Run from the repo root: lua5.4 tests/test_parser.lua
-- Adjust the Lua search path so require("logseq.parser") resolves relative
-- to the repo root regardless of which directory the test is launched from.
package.path = "../lua/?.lua;../lua/?/init.lua;./lua/?.lua;./lua/?/init.lua;" .. package.path

local parser = require("logseq.parser")

local pass_count = 0
local fail_count = 0

local function assert_eq(got, expected, msg)
  if got == expected then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected: " .. tostring(expected))
    print("  got:      " .. tostring(got))
  end
end

local function assert_table_eq(got, expected, msg)
  if #got ~= #expected then
    fail_count = fail_count + 1
    print("FAIL: " .. msg .. " (length mismatch: " .. #got .. " vs " .. #expected .. ")")
    return
  end
  for i = 1, #got do
    if got[i] ~= expected[i] then
      fail_count = fail_count + 1
      print("FAIL: " .. msg .. " (index " .. i .. ": " .. tostring(got[i]) .. " vs " .. tostring(expected[i]) .. ")")
      return
    end
  end
  pass_count = pass_count + 1
end

-- ── Test 1: Page properties ──────────────────────────────────────────

print("Test 1: Page properties")
local r = parser.parse({
  "status:: Done",
  "area:: Work",
  "",
  "- First block",
})
assert_eq(r.page_properties["status"], "Done", "page prop: status")
assert_eq(r.page_properties["area"], "Work", "page prop: area")
assert_eq(#r.blocks, 1, "one root block")

-- ── Test 2: Block tree structure ─────────────────────────────────────

print("Test 2: Block tree structure")
r = parser.parse({
  "- Root A",
  "  - Child A1",
  "    - Grandchild A1a",
  "  - Child A2",
  "- Root B",
})
assert_eq(#r.blocks, 2, "two root blocks")
assert_eq(r.blocks[1].content, "Root A", "root A content")
assert_eq(#r.blocks[1].children, 2, "root A has 2 children")
assert_eq(r.blocks[1].children[1].content, "Child A1", "child A1")
assert_eq(#r.blocks[1].children[1].children, 1, "A1 has 1 grandchild")
assert_eq(r.blocks[1].children[1].children[1].content, "Grandchild A1a", "grandchild")
assert_eq(r.blocks[1].children[2].content, "Child A2", "child A2")
assert_eq(r.blocks[2].content, "Root B", "root B")

-- ── Test 3: Block properties ─────────────────────────────────────────

print("Test 3: Block properties")
r = parser.parse({
  "- Read Deep Work",
  "  status:: done",
  "  priority:: high",
  "  - Sub-block",
})
local b = r.blocks[1]
assert_eq(b.properties["status"], "done", "block prop: status")
assert_eq(b.properties["priority"], "high", "block prop: priority")
assert_eq(#b.children, 1, "one child under propertied block")

-- ── Test 4: Line ranges ─────────────────────────────────────────────

print("Test 4: Line ranges")
r = parser.parse({
  "- Block 1",          -- line 1
  "  id:: abc-123",     -- line 2
  "  - Child 1",        -- line 3
  "    - Grandchild",   -- line 4
  "- Block 2",          -- line 5
})
assert_eq(r.blocks[1].line_start, 1, "block1 starts at 1")
assert_eq(r.blocks[1].line_end, 4, "block1 ends at 4 (covers all descendants)")
assert_eq(r.blocks[1].children[1].line_start, 3, "child starts at 3")
assert_eq(r.blocks[1].children[1].line_end, 4, "child ends at 4")
assert_eq(r.blocks[2].line_start, 5, "block2 starts at 5")
assert_eq(r.blocks[2].line_end, 5, "block2 ends at 5")

-- ── Test 5: Links and tags extraction ────────────────────────────────

print("Test 5: Links and tags")
r = parser.parse({
  "- Meeting about [[Project Alpha]] and #urgent",
  "  status:: [[Done]]",
  "- Check [[BJJ/Techniques/Triangle]]",
})
assert_table_eq(r.blocks[1].links, {"Project Alpha", "Done"}, "links on block 1")
assert_table_eq(r.blocks[1].tags, {"urgent"}, "tags on block 1")
assert_table_eq(r.blocks[2].links, {"BJJ/Techniques/Triangle"}, "links on block 2")

-- ── Test 6: block_at_line ────────────────────────────────────────────

print("Test 6: block_at_line")
r = parser.parse({
  "- Block 1",          -- 1
  "  id:: abc",         -- 2
  "  - Child",          -- 3
  "- Block 2",          -- 4
})
local found = parser.block_at_line(r.blocks, 1)
assert_eq(found and found.content, "Block 1", "line 1 → Block 1")
found = parser.block_at_line(r.blocks, 2)
assert_eq(found and found.content, "Block 1", "line 2 (property) → Block 1")
found = parser.block_at_line(r.blocks, 3)
assert_eq(found and found.content, "Child", "line 3 → Child")
found = parser.block_at_line(r.blocks, 4)
assert_eq(found and found.content, "Block 2", "line 4 → Block 2")

-- ── Test 7: Siblings and sibling_index ───────────────────────────────

print("Test 7: Siblings")
r = parser.parse({
  "- A",
  "  - A1",
  "  - A2",
  "- B",
})
local a1 = r.blocks[1].children[1]
local sibs = parser.siblings(a1, r.blocks)
assert_eq(#sibs, 2, "A1 has 2 siblings")
assert_eq(parser.sibling_index(a1, sibs), 1, "A1 is index 1")

local root_sibs = parser.siblings(r.blocks[1], r.blocks)
assert_eq(#root_sibs, 2, "root has 2 siblings")

-- ── Test 8: Flatten ──────────────────────────────────────────────────

print("Test 8: Flatten")
r = parser.parse({
  "- A",
  "  - A1",
  "    - A1a",
  "  - A2",
  "- B",
})
local flat = parser.flatten(r.blocks)
assert_eq(#flat, 5, "5 blocks total when flattened")
assert_eq(flat[1].content, "A", "flat[1] = A")
assert_eq(flat[2].content, "A1", "flat[2] = A1")
assert_eq(flat[3].content, "A1a", "flat[3] = A1a")
assert_eq(flat[4].content, "A2", "flat[4] = A2")
assert_eq(flat[5].content, "B", "flat[5] = B")

-- ── Test 9: Continuation lines ───────────────────────────────────────

print("Test 9: Continuation lines")
r = parser.parse({
  "- Block with",         -- 1
  "  continuation text",  -- 2
  "  and more text",      -- 3
  "  - Child block",      -- 4
})
assert_eq(r.blocks[1].line_start, 1, "multi-line block starts at 1")
assert_eq(r.blocks[1].line_end, 4, "multi-line block ends at 4 (with child)")
assert_eq(#r.blocks[1].children, 1, "has 1 child")
assert_eq(r.blocks[1].children[1].line_start, 4, "child at line 4")

-- ── Test 10: Empty/edge cases ────────────────────────────────────────

print("Test 10: Edge cases")
r = parser.parse({})
assert_eq(#r.blocks, 0, "empty file → no blocks")

r = parser.parse({ "status:: Active" })
assert_eq(#r.blocks, 0, "page props only → no blocks")
assert_eq(r.page_properties["status"], "Active", "page prop parsed")

r = parser.parse({ "- " })
assert_eq(#r.blocks, 1, "empty bullet parsed")
assert_eq(r.blocks[1].content, "", "empty bullet content is empty string")

-- ── Test 11: block_at_line recursive correctness ─────────────────────
-- Verifies the new recursive descent (audit #19) returns the same
-- results as the old flatten+scan approach.

print("Test 11: block_at_line recursive descent")
r = parser.parse({
  "- A",              -- 1
  "  id:: x",         -- 2
  "  - B",            -- 3
  "    - C",          -- 4
  "      - D",        -- 5
  "  - E",            -- 6
  "- F",              -- 7
})

found = parser.block_at_line(r.blocks, 1)
assert_eq(found and found.content, "A", "line 1 → A")
found = parser.block_at_line(r.blocks, 2)
assert_eq(found and found.content, "A", "line 2 (property of A) → A")
found = parser.block_at_line(r.blocks, 3)
assert_eq(found and found.content, "B", "line 3 → B")
found = parser.block_at_line(r.blocks, 4)
assert_eq(found and found.content, "C", "line 4 → C")
found = parser.block_at_line(r.blocks, 5)
assert_eq(found and found.content, "D", "line 5 → D (deepest)")
found = parser.block_at_line(r.blocks, 6)
assert_eq(found and found.content, "E", "line 6 → E")
found = parser.block_at_line(r.blocks, 7)
assert_eq(found and found.content, "F", "line 7 → F")

-- Out of range
found = parser.block_at_line(r.blocks, 99)
assert_eq(found, nil, "line 99 → nil")

-- ── Test 12: Inline SCHEDULED org-date extraction ────────────────────
-- SCHEDULED:: <2026-04-01 Wed> on the same line as the bullet content

print("Test 12: Inline SCHEDULED org-date")
r = parser.parse({
  "- TODO Send report. SCHEDULED:: <2026-04-01 Wed>",
})
local found_date = false
for _, l in ipairs(r.blocks[1].links) do
  if l == "2026-04-01" then found_date = true end
end
assert_eq(found_date, true, "inline SCHEDULED date in block.links")

-- ── Test 13: SCHEDULED on continuation line ───────────────────────────

print("Test 13: SCHEDULED on continuation line")
r = parser.parse({
  "- TODO Send report.",
  "  SCHEDULED:: <2026-04-01 Wed>",
})
found_date = false
for _, l in ipairs(r.blocks[1].links) do
  if l == "2026-04-01" then found_date = true end
end
assert_eq(found_date, true, "continuation SCHEDULED date in block.links")
assert_eq(r.blocks[1].properties["SCHEDULED"], "<2026-04-01 Wed>", "SCHEDULED property set")

-- ── Test 14: SCHEDULED on its own line, date on next continuation line

print("Test 14: SCHEDULED:: then date on next line")
r = parser.parse({
  "- TODO Send report.",
  "  SCHEDULED::",
  "  <2026-04-01 Wed>",
})
found_date = false
for _, l in ipairs(r.blocks[1].links) do
  if l == "2026-04-01" then found_date = true end
end
assert_eq(found_date, true, "split SCHEDULED date in block.links")

-- ── Test 15a: SCHEDULED at same indent as block (zero-indent) ────────
-- Logseq writes SCHEDULED at the block's own indent level, not indent+2.

print("Test 15a: SCHEDULED at block indent (single colon)")
r = parser.parse({
  "- TODO Send report.",
  "SCHEDULED: <2026-03-26 Wed>",
})
found_date = false
for _, l in ipairs(r.blocks[1].links) do
  if l == "2026-03-26" then found_date = true end
end
assert_eq(found_date,              true, "same-indent SCHEDULED: date in block.links")
assert_eq(r.blocks[1].is_scheduled, true, "same-indent SCHEDULED: sets is_scheduled")

print("Test 15b: SCHEDULED at block indent (double colon)")
r = parser.parse({
  "- TODO Send report.",
  "SCHEDULED:: <2026-03-26 Wed>",
})
found_date = false
for _, l in ipairs(r.blocks[1].links) do
  if l == "2026-03-26" then found_date = true end
end
assert_eq(found_date,              true, "same-indent SCHEDULED:: date in block.links")
assert_eq(r.blocks[1].is_scheduled, true, "same-indent SCHEDULED:: sets is_scheduled")
assert_eq(r.blocks[1].properties["SCHEDULED"], "<2026-03-26 Wed>", "SCHEDULED:: stored as property")

-- ── Test 15: page_property_refs ───────────────────────────────────────

print("Test 15: page_property_refs")
local refs = parser.page_property_refs({
  tags    = "[[ProjectX]] [[ProjectY]]",
  area    = "#Work",
  nothing = "plain text",
})
assert_eq(refs["ProjectX"], true, "[[ProjectX]] in page props")
assert_eq(refs["ProjectY"], true, "[[ProjectY]] in page props")
assert_eq(refs["Work"],     true, "#Work in page props")
assert_eq(refs["plain"],    nil,  "plain text not in refs")

-- Pipe alias stripping
refs = parser.page_property_refs({ related = "[[Real Page|Display Name]]" })
assert_eq(refs["Real Page"],    true, "pipe alias stripped to real page")
assert_eq(refs["Display Name"], nil,  "display name not in refs")

-- ── Summary ──────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
