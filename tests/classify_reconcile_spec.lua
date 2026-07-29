local classify = require("intentdiff.classify")

local function mk_hunk(file, n, line)
  return {
    id = file .. ":" .. n, file = file, status = "M",
    header = "@@", text = "@@\n", content_hash = tostring(line),
    original = { start_line = line, end_line = line + 1 },
    modified = { start_line = line, end_line = line + 1 },
  }
end

local function mk_inventory()
  return {
    hunks = { mk_hunk("a.lua", 1, 1), mk_hunk("a.lua", 2, 50), mk_hunk("b.lua", 1, 3) },
    files = { { path = "a.lua", status = "M" }, { path = "b.lua", status = "M" } },
    diff_text = "", diff_hash = "x",
  }
end

describe("classify.reconcile", function()
  it("assigns hunks, sweeps missed ones into Ungrouped", function()
    local groups = classify.reconcile(mk_inventory(), {
      { title = "Feature", hunk_ids = { "a.lua:1", "b.lua:1" } },
    })
    assert.equals(2, #groups)
    assert.equals("Feature", groups[1].title)
    assert.equals(2, #groups[1].hunks)
    assert.equals("Ungrouped", groups[2].title)
    assert.is_true(groups[2].is_ungrouped)
    assert.equals("a.lua:2", groups[2].hunks[1].id)
  end)

  it("drops hallucinated ids and deduplicates across groups", function()
    local groups = classify.reconcile(mk_inventory(), {
      { title = "G1", hunk_ids = { "a.lua:1", "ghost.lua:9" } },
      { title = "G2", hunk_ids = { "a.lua:1", "a.lua:2", "b.lua:1" } },
    })
    assert.equals(1, #groups[1].hunks) -- ghost dropped
    assert.equals(2, #groups[2].hunks) -- a.lua:1 kept in G1 only
  end)

  it("drops empty groups entirely", function()
    local groups = classify.reconcile(mk_inventory(), {
      { title = "Empty", hunk_ids = { "ghost:1" } },
      { title = "All", hunk_ids = { "a.lua:1", "a.lua:2", "b.lua:1" } },
    })
    assert.equals(1, #groups)
    assert.equals("All", groups[1].title)
  end)

  it("INVARIANT: union of groups == inventory for arbitrary assignments", function()
    local inv = mk_inventory()
    local cases = {
      {}, -- provider returned nothing
      { { title = "T", hunk_ids = {} } },
      { { title = "T" } }, -- hunk_ids missing entirely
      { { title = "A", hunk_ids = { "b.lua:1" } }, { title = "B", hunk_ids = { "b.lua:1", "zz:1" } } },
    }
    for _, raw in ipairs(cases) do
      local groups = classify.reconcile(inv, raw)
      local seen = {}
      for _, g in ipairs(groups) do
        for _, h in ipairs(g.hunks) do
          assert.is_nil(seen[h.id], "duplicate " .. h.id)
          seen[h.id] = true
        end
      end
      for _, h in ipairs(inv.hunks) do
        assert.is_true(seen[h.id], "missing " .. h.id)
      end
    end
  end)

  it("builds per-file entries ordered by diff order then start line", function()
    local groups = classify.reconcile(mk_inventory(), {
      { title = "T", hunk_ids = { "b.lua:1", "a.lua:2", "a.lua:1" } },
    })
    local files = groups[1].files
    assert.equals("a.lua", files[1].path)
    assert.equals(1, files[1].hunks[1].modified.start_line)
    assert.equals(50, files[1].hunks[2].modified.start_line)
    assert.equals("b.lua", files[2].path)
  end)
end)
