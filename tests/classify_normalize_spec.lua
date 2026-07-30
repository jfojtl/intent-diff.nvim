local classify = require("intentdiff.classify")

-- Shared numbering for every case below: 3 hunks, numbered 1..3 in inventory
-- order (exactly what classify.build_request produces).
local NUMBERING = { [1] = "a.lua:1", [2] = "a.lua:2", [3] = "b.lua:1" }

describe("classify.normalize_raw_groups: compact `ids` expansion", function()
  -- Table-driven: { desc, raw_groups, expected hunk_ids for group 1 }.
  -- Every case must (a) never throw and (b) produce exactly the listed ids,
  -- in order, deduplicated.
  local cases = {
    { desc = "simple range", ids = "1-3", expect = { "a.lua:1", "a.lua:2", "b.lua:1" } },
    { desc = "comma list", ids = "1,3", expect = { "a.lua:1", "b.lua:1" } },
    { desc = "whitespace around numbers and dashes", ids = " 1 - 2 ", expect = { "a.lua:1", "a.lua:2" } },
    { desc = "trailing and duplicate commas", ids = "1,,2,,", expect = { "a.lua:1", "a.lua:2" } },
    { desc = "reversed range", ids = "3-1", expect = { "a.lua:1", "a.lua:2", "b.lua:1" } },
    { desc = "reversed range with whitespace", ids = "2 - 1", expect = { "a.lua:1", "a.lua:2" } },
    { desc = "out-of-range number dropped", ids = "99", expect = {} },
    { desc = "negative bare number dropped", ids = "-5", expect = {} },
    { desc = "non-numeric token dropped, valid numbers kept", ids = "1,foo,2", expect = { "a.lua:1", "a.lua:2" } },
    { desc = "mixed valid/out-of-range in one range", ids = "2-4", expect = { "a.lua:2", "b.lua:1" } },
    { desc = "empty string maps to nothing", ids = "", expect = {} },
    { desc = "only commas", ids = ",,,", expect = {} },
    { desc = "JSON array of numbers", ids = { 1, 2 }, expect = { "a.lua:1", "a.lua:2" } },
    { desc = "JSON array with an out-of-range entry", ids = { 1, 42 }, expect = { "a.lua:1" } },
    { desc = "JSON array of numeric strings", ids = { "1", "3" }, expect = { "a.lua:1", "b.lua:1" } },
    { desc = "bare number", ids = 2, expect = { "a.lua:2" } },
    { desc = "duplicate numbers dedupe", ids = "1,1,1", expect = { "a.lua:1" } },
    { desc = "huge range does not hang and yields nothing", ids = "1-999999999999999", expect = {} },
    -- tonumber("2.0") is 2.0 in Lua; we floor it to 2 rather than rejecting
    -- it outright — permissive, since the model is instructed to emit plain
    -- integers but nothing downstream cares if it adds ".0".
    { desc = "float-ish string number floors to an int", ids = "2.0", expect = { "a.lua:2" } },
  }

  for _, case in ipairs(cases) do
    it(("expands %s (%s) correctly"):format(case.desc, vim.inspect(case.ids)), function()
      local ok, raw = pcall(classify.normalize_raw_groups, { { title = "T", ids = case.ids } }, NUMBERING)
      assert.is_true(ok, "normalize_raw_groups threw: " .. tostring(raw))
      assert.same(case.expect, raw[1].hunk_ids)
    end)
  end

  it("never throws when numbering is nil (drops everything)", function()
    local ok, raw = pcall(classify.normalize_raw_groups, { { title = "T", ids = "1-3" } }, nil)
    assert.is_true(ok, tostring(raw))
    assert.same({}, raw[1].hunk_ids)
  end)

  it("never throws on completely malformed ids shapes (booleans, nested tables, nil-holed arrays)", function()
    local weird = {
      { title = "A", ids = true },
      { title = "B", ids = { true, {}, "1" } },
      { title = "C", ids = {} },
      { title = "D" }, -- no ids, no hunk_ids at all
      "not even a table",
    }
    local ok, raw = pcall(classify.normalize_raw_groups, weird, NUMBERING)
    assert.is_true(ok, tostring(raw))
    assert.same({}, raw[1].hunk_ids)
    assert.same({ "a.lua:1" }, raw[2].hunk_ids)
    assert.same({}, raw[3].hunk_ids)
    assert.same({}, raw[4].hunk_ids)
  end)

  it("legacy hunk_ids arrays pass through unchanged", function()
    local raw = classify.normalize_raw_groups({
      { title = "Legacy", hunk_ids = { "a.lua:1", "b.lua:1" } },
    }, NUMBERING)
    assert.same({ "a.lua:1", "b.lua:1" }, raw[1].hunk_ids)
  end)

  it("merges legacy hunk_ids and compact ids on the SAME group, deduplicated", function()
    local raw = classify.normalize_raw_groups({
      { title = "Mixed", hunk_ids = { "b.lua:1" }, ids = "1,3" }, -- 3 -> b.lua:1, dup with hunk_ids
    }, NUMBERING)
    assert.same({ "b.lua:1", "a.lua:1" }, raw[1].hunk_ids)
  end)

  it("both shapes may appear across different groups in one response", function()
    local raw = classify.normalize_raw_groups({
      { title = "Legacy group", hunk_ids = { "a.lua:1" } },
      { title = "Compact group", ids = "3" },
    }, NUMBERING)
    assert.same({ "a.lua:1" }, raw[1].hunk_ids)
    assert.same({ "b.lua:1" }, raw[2].hunk_ids)
  end)

  it("reports mapping failures via the second return value", function()
    local _, dropped = classify.normalize_raw_groups({
      { title = "T", ids = "1,99,-4,42" }, -- only 1 maps
    }, NUMBERING)
    assert.equals(3, dropped)
  end)

  it("mapping failures are 0 when everything maps", function()
    local _, dropped = classify.normalize_raw_groups({
      { title = "T", ids = "1-3" },
    }, NUMBERING)
    assert.equals(0, dropped)
  end)
end)

describe("classify.normalize_raw_groups: end-to-end completeness with classify.reconcile", function()
  local function mk_inventory()
    local function h(file, n, line)
      return {
        id = file .. ":" .. n, file = file, status = "M",
        header = "@@", text = "@@\n", content_hash = tostring(line),
        original = { start_line = line, end_line = line + 1 },
        modified = { start_line = line, end_line = line + 1 },
      }
    end
    return {
      hunks = { h("a.lua", 1, 1), h("a.lua", 2, 50), h("b.lua", 1, 3) },
      files = { { path = "a.lua", status = "M" }, { path = "b.lua", status = "M" } },
      diff_text = "", diff_hash = "x",
    }
  end

  it("compact ids covering only some hunks land the rest in Ungrouped", function()
    local inv = mk_inventory()
    local raw = classify.normalize_raw_groups({
      { title = "Feature", ids = "1" }, -- covers only a.lua:1
    }, NUMBERING)
    local groups, stats = classify.reconcile(inv, raw)
    assert.equals(2, #groups)
    assert.equals("Feature", groups[1].title)
    assert.equals(1, #groups[1].hunks)
    assert.equals("Ungrouped", groups[2].title)
    assert.equals(2, #groups[2].hunks)
    assert.equals(1, stats.assigned)
    assert.equals(2, stats.ungrouped)
  end)

  it("garbage ids put every hunk in Ungrouped", function()
    local inv = mk_inventory()
    local raw = classify.normalize_raw_groups({
      { title = "Garbage", ids = "not,a,number,999,-1" },
    }, NUMBERING)
    local groups, stats = classify.reconcile(inv, raw)
    assert.equals(1, #groups)
    assert.equals("Ungrouped", groups[1].title)
    assert.equals(3, #groups[1].hunks)
    assert.equals(0, stats.assigned)
    assert.equals(3, stats.ungrouped)
  end)

  it("full range covers everything, no Ungrouped group", function()
    local inv = mk_inventory()
    local raw = classify.normalize_raw_groups({
      { title = "Everything", ids = "1-3" },
    }, NUMBERING)
    local groups = classify.reconcile(inv, raw)
    assert.equals(1, #groups)
    assert.equals("Everything", groups[1].title)
    assert.equals(3, #groups[1].hunks)
  end)
end)
